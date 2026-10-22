use crate::{model::*, store::Store};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{error::Error, io::Read, path::Path, sync::Arc};
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Credential {
    pub id: String,
    pub token: String,
    pub role: String,
    pub host_id: Option<String>,
    #[serde(default)]
    pub revoked: bool,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub listen: String,
    pub database: String,
    pub credentials: Vec<Credential>,
    pub apns: Option<crate::apns::Config>,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            listen: "127.0.0.1:8787".into(),
            database: "agentinbox.sqlite".into(),
            credentials: vec![],
            apns: None,
        }
    }
}
pub fn authorize<'a>(
    config: &'a Config,
    authorization: &str,
    host: bool,
) -> ApiResult<&'a Credential> {
    let token = authorization
        .strip_prefix("Bearer ")
        .ok_or_else(|| error(401, "authentication required"))?;
    let c = config
        .credentials
        .iter()
        .find(|c| !c.revoked && constant_eq(c.token.as_bytes(), token.as_bytes()))
        .ok_or_else(|| error(401, "invalid or revoked credential"))?;
    if host && (c.role != "host" || c.host_id.is_none()) {
        return Err(error(403, "host credential required"));
    }
    if !host && !["device", "host"].contains(&c.role.as_str()) {
        return Err(error(403, "unsupported role"));
    }
    Ok(c)
}
fn constant_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut d = 0;
    for (x, y) in a.iter().zip(b) {
        d |= x ^ y
    }
    d == 0
}
fn load(path: &Path) -> Result<Config, Box<dyn Error>> {
    let c: Config = serde_json::from_slice(&std::fs::read(path)?)?;
    let mut tokens = std::collections::HashSet::new();
    let mut ids = std::collections::HashSet::new();
    for cred in &c.credentials {
        if cred.token.len() < 20
            || !tokens.insert(&cred.token)
            || !ids.insert(&cred.id)
            || !["host", "device"].contains(&cred.role.as_str())
            || (cred.role == "host" && cred.host_id.as_deref().unwrap_or("").is_empty())
        {
            return Err("invalid, short or duplicate credentials".into());
        }
    }
    Ok(c)
}
pub fn run(args: &[String]) -> Result<(), Box<dyn Error>> {
    let path = args
        .windows(2)
        .find(|w| w[0] == "--config")
        .map(|w| w[1].as_str())
        .unwrap_or("config/relay.local.json");
    let config = load(Path::new(path))?;
    let listen: std::net::SocketAddr = config.listen.parse()?;
    if !listen.ip().is_loopback() {
        return Err("non-loopback listener requires deployment approval; local relay only".into());
    }
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(format!("{}.relay.lock", config.database))?;
    fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| "relay already owns this database")?;
    let store = Arc::new(Store::open(&config.database)?);
    if let Some(code_file) = args.windows(2).find(|w| w[0] == "--pair-code-file") {
        let code = std::fs::read_to_string(&code_file[1])?;
        store.add_pair_code(code.trim(), now())?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&config.database, std::fs::Permissions::from_mode(0o600))?;
        for file in [
            format!("{}-wal", config.database),
            format!("{}-shm", config.database),
            format!("{}.relay.lock", config.database),
        ] {
            if std::path::Path::new(&file).exists() {
                std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o600))?;
            }
        }
    }
    let server = tiny_http::Server::http(listen).map_err(|_| "unable to bind relay listener")?;
    if let Some(apns) = config.apns {
        let store = store.clone();
        let worker_config_path = Path::new(path).to_path_buf();
        std::thread::spawn(move || crate::apns::worker(store, apns, worker_config_path));
    }
    eprintln!("AgentInbox relay listening on {}", listen);
    for mut req in server.incoming_requests() {
        let result = (|| -> ApiResult<Value> {
            let config =
                load(Path::new(path)).map_err(|_| error(503, "credential config unavailable"))?;
            let url = req.url().to_owned();
            let path = url.split('?').next().unwrap_or("");
            let host = path.starts_with("/v1/host/");
            let authorization = req
                .headers()
                .iter()
                .find(|h| h.field.equiv("Authorization"))
                .map(|h| h.value.as_str())
                .unwrap_or("");
            let dynamic;
            let cred = if path == "/v1/pair" {
                dynamic = Credential {
                    id: "pair".into(),
                    token: String::new(),
                    role: "pair".into(),
                    host_id: None,
                    revoked: false,
                };
                &dynamic
            } else {
                match authorize(&config, authorization, host) {
                    Ok(c) => c,
                    Err(original) => {
                        let token = authorization.strip_prefix("Bearer ").unwrap_or("");
                        if let Some(id) = store.device_credential(token)? {
                            dynamic = Credential {
                                id,
                                token: String::new(),
                                role: "device".into(),
                                host_id: None,
                                revoked: false,
                            };
                            if host {
                                return Err(error(403, "host credential required"));
                            }
                            &dynamic
                        } else {
                            return Err(original);
                        }
                    }
                }
            };
            if store.is_revoked(&cred.id)? {
                return Err(error(401, "device credential revoked"));
            }
            if !url.starts_with("/v1/") {
                return Err(error(404, "endpoint not found"));
            }
            let is_post = req.method() == &tiny_http::Method::Post;
            let body = if is_post {
                let mut buffer = Vec::new();
                req.as_reader()
                    .take(262145)
                    .read_to_end(&mut buffer)
                    .map_err(|_| error(400, "body unreadable"))?;
                if buffer.len() > 262144 {
                    return Err(error(413, "request body too large"));
                }
                serde_json::from_slice(&buffer)?
            } else {
                json!({})
            };
            route(&store, cred, req.method().as_str(), &url, body, now())
        })();
        let (status, payload) = match result {
            Ok(v) => (200, v),
            Err(e) => (e.status, json!({"error":e.message})),
        };
        let response = tiny_http::Response::from_string(payload.to_string())
            .with_status_code(status)
            .with_header(
                tiny_http::Header::from_bytes("Content-Type", "application/json; charset=utf-8")
                    .unwrap(),
            )
            .with_header(tiny_http::Header::from_bytes("Cache-Control", "no-store").unwrap());
        let _ = req.respond(response);
    }
    Ok(())
}
fn route(
    s: &Store,
    c: &Credential,
    method: &str,
    url: &str,
    body: Value,
    time: i64,
) -> ApiResult<Value> {
    let path = url.split('?').next().unwrap_or("");
    let host = c.host_id.as_deref().unwrap_or("");
    match (method, path) {
        ("POST", "/v1/pair") => s.pair(
            string(&body, "code")?,
            body["name"].as_str().unwrap_or("iPhone"),
            time,
        ),
        ("GET", "/v1/requests") => {
            let requests = s.list(time)?;
            Ok(
                json!({"requests":requests.into_iter().filter(|q|c.role=="device"||q["hostId"]==host).collect::<Vec<_>>()}),
            )
        }
        ("GET", "/v1/capabilities") => {
            Ok(json!({"replyProgressVersion":1,"bindingDigestVersion":1}))
        }
        ("GET", "/v1/host/reply-progress") => Ok(json!({"requests":s.incomplete_progress(host)?})),
        ("GET", "/v1/hosts") => s.hosts(time),
        ("GET", "/v1/host/requests") => Ok(json!({"requests":s.active_for_host(host,time)?})),
        ("GET", "/v1/host/upgrade-status") => s.upgrade_status(host, time),
        ("POST", "/v1/host/requests") => s.create(host, body, time),
        ("POST", "/v1/host/heartbeat") => {
            if body.get("hostId").is_some_and(|id| id != host) {
                return Err(error(403, "host binding mismatch"));
            }
            s.heartbeat(host, time)
        }
        ("GET", "/v1/host/responses") => {
            let query = url.split_once('?').map(|(_, q)| q).unwrap_or("");
            let pairs: std::collections::HashMap<_, _> =
                query.split('&').filter_map(|s| s.split_once('=')).collect();
            if pairs.get("hostId").is_some_and(|id| *id != host) {
                return Err(error(403, "host binding mismatch"));
            }
            let id = pairs
                .get("requestId")
                .copied()
                .ok_or_else(|| error(400, "requestId required for atomic single request claim"))?;
            let q = s.get(id, true)?;
            if q["hostId"] != host {
                return Err(error(403, "host binding mismatch"));
            }
            Ok(json!({"responses":s.claim_one(host,id,time)?}))
        }
        ("POST", "/v1/host/receipt") => s.receipt(host, body, time),
        ("GET", "/v1/devices/widget-token") => {
            if c.role != "device" {
                return Err(error(403, "device credential required"));
            }
            Ok(json!({"registrationRevision":s.widget_registration_revision(&c.id)?}))
        }
        ("POST", "/v1/devices/widget-token") => {
            if c.role != "device" {
                return Err(error(403, "device credential required"));
            }
            let active = match body.get("active") {
                None => true,
                Some(v) => v
                    .as_bool()
                    .ok_or_else(|| error(400, "active must be boolean"))?,
            };
            s.widget_token(
                &c.id,
                string(&body, "token")?,
                string(&body, "environment")?,
                active,
                body["registrationRevision"]
                    .as_i64()
                    .filter(|n| *n > 0)
                    .ok_or_else(|| error(400, "registrationRevision must be a positive int64"))?,
                time,
            )
        }
        ("POST", "/v1/devices/token") => {
            if c.role != "device" {
                return Err(error(403, "device credential required"));
            }
            s.device_token(
                &c.id,
                string(&body, "token")?,
                string(&body, "environment")?,
            )
        }
        ("POST", "/v1/devices/revoke") => {
            if c.role != "device" {
                return Err(error(403, "device credential required"));
            }
            s.revoke_device(&c.id)?;
            Ok(json!({"revoked":true}))
        }
        _ => {
            if let Some(rest) = path.strip_prefix("/v1/requests/") {
                if let Some(id) = rest.strip_suffix("/responses") {
                    if method != "POST" || c.role != "device" {
                        return Err(error(403, "device response operation required"));
                    }
                    if body["requestId"] != id {
                        return Err(error(409, "path/request binding mismatch"));
                    }
                    return s.respond(&c.id, body, time);
                }
                if method == "GET" {
                    let q = s.get(rest, c.role == "host")?;
                    if c.role == "host" && q["hostId"] != host {
                        return Err(error(403, "host binding mismatch"));
                    }
                    return Ok(q);
                }
            }
            Err(error(404, "endpoint not found"))
        }
    }
}

/// Re-read static credential revocation/removal immediately before Widget HTTP.
/// Paired identities still require the worker's live DB revocation predicate.
pub(crate) fn widget_device_identity_enabled(path: &Path, id: &str, paired: bool) -> bool {
    let Ok(config) = load(path) else { return false };
    match config.credentials.iter().find(|c| c.id == id) {
        Some(c) => c.role == "device" && !c.revoked,
        None => paired,
    }
}
