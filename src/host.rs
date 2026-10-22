use crate::{
    adapters::{claude, codex},
    client,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    os::unix::{
        fs::PermissionsExt,
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    process::Command,
    sync::mpsc,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tungstenite::{Message, WebSocket};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub host_id: String,
    pub relay_url: String,
    pub token_file: PathBuf,
    pub state_dir: PathBuf,
    pub ipc_socket: PathBuf,
    #[serde(default)]
    pub codex_socket: Option<PathBuf>,
    /// Opt-in private journal produced by the patched native arbitration point.
    #[serde(default)]
    pub native_receipt_dir: Option<PathBuf>,
    #[serde(default)]
    pub daemon_pid: Option<u32>,
    pub scopes: Vec<PathBuf>,
    #[serde(default)]
    pub capture_all_directories: bool,
    #[serde(default)]
    pub thread_ids: Vec<String>,
    #[serde(default)]
    pub excluded_session_ids: Vec<String>,
    #[serde(default)]
    pub capture_loaded_native: bool,
    #[serde(default)]
    pub daemon_peer_pid: Option<u32>,
    #[serde(default = "default_ttl")]
    pub request_ttl: i64,
    /// Only controlled fixtures with exact final-turn echoes can use this evidence method.
    #[serde(default)]
    pub adoption_marker: Option<String>,
}
impl Config {
    fn captures_directory(&self, cwd: &Path) -> bool {
        cwd.is_absolute()
            && (self.capture_all_directories || self.scopes.iter().any(|scope| scope == cwd))
    }
    pub fn captures_session(&self, session: &str) -> bool {
        !session.trim().is_empty() && !self.excluded_session_ids.iter().any(|id| id == session)
    }
}
fn codex_list_params(scope: Option<&Path>, cursor: Option<&str>) -> Value {
    let mut params = json!({"limit":100,"useStateDbOnly":true});
    if let Some(scope) = scope {
        params["cwd"] = json!(scope);
    }
    if let Some(cursor) = cursor {
        params["cursor"] = json!(cursor);
    }
    params
}
fn default_ttl() -> i64 {
    600
}
pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}
fn private_dir(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    if path.exists() {
        let m = fs::symlink_metadata(path)?;
        if !m.is_dir() || m.file_type().is_symlink() || m.permissions().mode() & 0o077 != 0 {
            return Err(
                "existing service directory must be private; refusing shared directory chmod"
                    .into(),
            );
        }
    } else {
        fs::create_dir_all(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
pub fn generation(pid: u32) -> Result<String, String> {
    generation_for(pid, false)
}
fn generation_for(pid: u32, standalone_receipt_engine: bool) -> Result<String, String> {
    let out = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "lstart=", "-o", "command="])
        .output()
        .map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if !out.status.success()
        || text.is_empty()
        || !text.contains("app-server")
        || (!standalone_receipt_engine && !text.contains("--managed-daemon"))
    {
        return Err("configured PID is not the active managed app-server".into());
    }
    let start = text
        .split_whitespace()
        .take(5)
        .collect::<Vec<_>>()
        .join(" ");
    Ok(format!("{pid}:{start}"))
}
struct Incoming {
    event: Value,
    stream: UnixStream,
}
struct Pending {
    turn_completed: bool,
    published: bool,
    request: Value,
    callback: Value,
    hook: Option<UnixStream>,
    response: Option<Value>,
    resolved: bool,
    final_text: Option<String>,
    sent_at: Option<Instant>,
    expected: Option<String>,
    boundary: Option<crate::reply_evidence::DispatchBoundary>,
    native_source: Option<crate::native_receipt::Source>,
    native_dispatch: Option<crate::native_receipt::Dispatch>,
    recorded_progress: Option<Value>,
    continuation_unknown: bool,
    blocked_receipt: Option<(String, Value)>,
}
fn receipt(
    c: &Config,
    token: &str,
    p: &Pending,
    state: &str,
    evidence: Value,
) -> Result<Value, String> {
    let mut payload = json!({"hostId":c.host_id,"requestId":p.request["requestId"],"responseId":p.response.as_ref().map(|r|r["responseId"].clone()),"state":state,"evidence":evidence});
    let progress = if matches!(state, "adopted" | "unknown") {
        progress_envelope(
            p,
            attributed_observation(p),
            state == "unknown" || p.continuation_unknown,
        )
    } else {
        None
    };
    if let Some(progress) = progress {
        payload["state"] = json!("adopted");
        payload["replyProgress"] = progress;
    } else if state == "adopted" {
        payload["nativeObservation"] = json!("answerSourceUnconfirmed");
    }
    let path = persist_receipt(&c.state_dir, &payload)?;
    deliver_receipt(c, token, &path, payload)
}
pub fn persist_receipt(state_dir: &Path, payload: &Value) -> Result<PathBuf, String> {
    let id = payload["requestId"]
        .as_str()
        .ok_or("receipt missing request ID")?;
    let state = payload["state"].as_str().ok_or("receipt missing state")?;
    if !id
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        || ![
            "adopted",
            "handledLocally",
            "expired",
            "invalidated",
            "unknown",
        ]
        .contains(&state)
    {
        return Err("invalid receipt identity".into());
    }
    let dir = state_dir.join("receipt-outbox");
    private_dir(&dir).map_err(|e| e.to_string())?;
    let suffix = payload
        .get("replyProgress")
        .map(|p| {
            use sha2::{Digest, Sha256};
            format!("-{:x}", Sha256::digest(p.to_string()))
        })
        .unwrap_or_default();
    let path = dir.join(format!("{id}-{state}{suffix}.json"));
    let temp = dir.join(format!("temporary-{}", uuid::Uuid::new_v4()));
    let mut f = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temp)
        .map_err(|e| e.to_string())?;
    writeln!(f, "{}", payload).map_err(|e| e.to_string())?;
    f.sync_all().map_err(|e| e.to_string())?;
    fs::rename(temp, &path).map_err(|e| e.to_string())?;
    fs::File::open(dir)
        .and_then(|f| f.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(path)
}
fn deliver_receipt(
    c: &Config,
    token: &str,
    path: &Path,
    mut payload: Value,
) -> Result<Value, String> {
    // A device may have committed its candidate immediately before the local callback resolved.
    // Read that responseId for reconciliation only; never claim or dispatch its answer.
    let id = payload["requestId"]
        .as_str()
        .ok_or("receipt request ID missing")?;
    let latest = match client::get_json(&c.relay_url, token, &format!("/v1/requests/{id}")) {
        Ok(q) => q,
        Err(e) if e.starts_with("HTTP 404:") => {
            archive_receipt(c, path, &payload, "request absent at authenticated relay")?;
            return Ok(json!({"receiptArchived":true}));
        }
        Err(e) => return Err(e),
    };
    if latest["hostId"] != c.host_id {
        return Err("receipt host mismatch".into());
    }
    let latest_state = latest["state"].as_str().unwrap_or("");
    if ["adopted", "handledLocally", "expired", "invalidated"].contains(&latest_state)
        && payload["state"] != latest["state"]
    {
        archive_receipt(
            c,
            path,
            &payload,
            &format!("relay already terminal: {latest_state}; retained as conflict evidence"),
        )?;
        return Ok(latest);
    }
    if latest["hostId"] != c.host_id {
        return Err("receipt host mismatch".into());
    }
    if payload["responseId"].is_null() {
        payload["responseId"] = latest["responseId"].clone();
    }
    if payload["responseId"] != latest["responseId"] {
        return Err("receipt candidate changed; retained without delivery".into());
    }
    if payload.get("replyProgress").is_some() || payload.get("nativeObservation").is_some() {
        match client::get_json(&c.relay_url, token, "/v1/capabilities") {
            Ok(cap) if cap["replyProgressVersion"] == 1 => {}
            Err(e) if e.starts_with("HTTP 404:") && payload.get("replyProgress").is_none() => {
                payload.as_object_mut().unwrap().remove("nativeObservation");
            }
            _ => {
                return Err(
                    "relay progress capability unavailable; durable receipt retained".into(),
                );
            }
        }
    }
    let result = match client::post_json(&c.relay_url, token, "/v1/host/receipt", &payload) {
        Ok(result) => result,
        Err(e) if e.starts_with("HTTP 409:") => {
            archive_receipt(
                c,
                path,
                &payload,
                "authenticated relay rejected receipt as conflicting; no replay",
            )?;
            return Ok(latest);
        }
        Err(e) => return Err(e),
    };
    fs::remove_file(path).map_err(|e| e.to_string())?;
    Ok(result)
}
pub fn flush_receipts(c: &Config, token: &str) -> usize {
    let Ok(entries) = fs::read_dir(c.state_dir.join("receipt-outbox")) else {
        return 0;
    };
    let mut delivered = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(bytes) = fs::read(&path) else { continue };
        let Ok(payload) = serde_json::from_slice::<Value>(&bytes) else {
            continue;
        };
        match deliver_receipt(c, token, &path, payload) {
            Ok(_) => delivered += 1,
            Err(e) if e.contains("connection failed") => break,
            Err(_) => {}
        }
    }
    delivered
}
fn send(ws: &mut WebSocket<UnixStream>, v: Value) -> Result<(), Box<dyn std::error::Error>> {
    ws.send(Message::Text(v.to_string()))?;
    Ok(())
}
fn callback_key(m: &Value) -> String {
    format!(
        "{}:{}:{}:{}",
        m["params"]["threadId"], m["params"]["turnId"], m["params"]["itemId"], m["id"]
    )
}
fn publish(c: &Config, token: &str, request: &Value) -> Result<Value, String> {
    client::post_json(&c.relay_url, token, "/v1/host/requests", request)
}
fn claim(c: &Config, p: &Pending) -> Result<(), Box<dyn std::error::Error>> {
    let id = p.request["requestId"]
        .as_str()
        .ok_or("missing product ID")?;
    let path = c.state_dir.join(format!("dispatch-{id}"));
    let mut f = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(path)?;
    writeln!(
        f,
        "{}",
        json!({"requestId":id,"responseId":p.response.as_ref().map(|r|&r["responseId"]),"claimedAt":now(),"state":"claimed-before-dispatch; no blind retry","request":p.request,"callback":p.callback,"response":p.response,"boundary":p.boundary,"nativeSource":p.native_source,"nativeDispatch":p.native_dispatch})
    )?;
    f.sync_all()?;
    fs::File::open(&c.state_dir)?.sync_all()?;
    Ok(())
}
use std::os::unix::fs::OpenOptionsExt;
pub fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let path = args.first().ok_or("host CONFIG.json required")?;
    let mut c: Config = serde_json::from_str(&fs::read_to_string(path)?)?;
    let discovery = crate::discovery::start_from_args(&args[1..], &c.host_id)?;
    if c.request_ttl < 10 || c.request_ttl > 3600 {
        return Err("TTL must be 10..3600 seconds".into());
    }
    c.scopes = c
        .scopes
        .iter()
        .map(fs::canonicalize)
        .collect::<Result<Vec<_>, _>>()?;
    if c.scopes.is_empty() && !c.capture_all_directories {
        return Err("explicit canonical scopes required".into());
    }
    let _host_lease = host_lease(&c.host_id)?;
    private_dir(&c.state_dir)?;
    let original_state_dir = c.state_dir.clone();
    let relative_socket = c
        .ipc_socket
        .strip_prefix(&original_state_dir)
        .map_err(|_| "IPC must be inside stateDir")?
        .to_path_buf();
    if relative_socket.components().any(|v| {
        matches!(
            v,
            std::path::Component::ParentDir
                | std::path::Component::RootDir
                | std::path::Component::Prefix(_)
        )
    }) {
        return Err("IPC path traversal refused".into());
    }
    c.state_dir = fs::canonicalize(&c.state_dir)?;
    c.ipc_socket = c.state_dir.join(relative_socket);
    let ipc_parent = c.ipc_socket.parent().ok_or("IPC parent required")?;
    if !ipc_parent.starts_with(&c.state_dir) {
        return Err(
            "IPC must be inside the dedicated host stateDir; refusing shared-directory chmod"
                .into(),
        );
    }
    private_dir(ipc_parent)?;
    if c.ipc_socket.exists() {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};
        let meta = fs::symlink_metadata(&c.ipc_socket)?;
        if !meta.file_type().is_socket()
            || meta.file_type().is_symlink()
            || meta.uid() != current_uid()
        {
            return Err("IPC path is not a private owned socket; refusing unlink".into());
        }
        match UnixStream::connect(&c.ipc_socket) {
            Ok(_) => return Err("IPC has an active owner; refusing replacement".into()),
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound
                ) =>
            {
                fs::remove_file(&c.ipc_socket)?;
            }
            Err(_) => return Err("cannot prove stale IPC socket; refusing replacement".into()),
        }
    }
    let token_meta = fs::metadata(&c.token_file)?;
    if token_meta.permissions().mode() & 0o077 != 0 {
        return Err("host tokenFile must be private mode 0600".into());
    }
    let token = fs::read_to_string(&c.token_file)?.trim().to_string();
    flush_receipts(&c, &token);
    let mut startup_reconciled = reconcile_startup(&c, &token)
        .and_then(|_| reconcile_native_dispatches(&c, &token))
        .and_then(|_| reconcile_progress_startup(&c, &token))
        .is_ok();
    let runtime = format!("host-{}", uuid::Uuid::new_v4());
    let listener = UnixListener::bind(&c.ipc_socket)?;
    fs::set_permissions(&c.ipc_socket, fs::Permissions::from_mode(0o600))?;
    if let Some((server, info)) = discovery {
        thread::spawn(move || {
            loop {
                if crate::discovery::serve_one(&server, &info).is_err() {
                    // A disconnected probe is harmless; no task or credential is handled here.
                    continue;
                }
            }
        });
    }
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        for s in listener.incoming() {
            if let Ok(mut stream) = s {
                let tx = tx.clone();
                thread::spawn(move || {
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
                    let mut line = String::new();
                    if BufReader::new(&mut stream).read_line(&mut line).is_ok() {
                        if let Ok(event) = serde_json::from_str(&line) {
                            let _ = tx.send(Incoming { event, stream });
                        }
                    }
                });
            }
        }
    });
    let mut ws = None;
    let mut daemon_gen = None;
    let mut native_source = None;
    if c.native_receipt_dir.is_some() && c.codex_socket.is_none() {
        return Err("native receipt source requires its native Unix socket".into());
    }
    if let Some(socket) = &c.codex_socket {
        let stream = UnixStream::connect(socket)?;
        let actual_peer = peer_pid(&stream)?;
        if peer_uid(&stream)? != current_uid() {
            return Err("Codex Unix peer UID differs from current user".into());
        }
        if c.daemon_pid.is_some_and(|expected| expected != actual_peer)
            || c.daemon_peer_pid
                .is_some_and(|expected| expected != actual_peer)
        {
            return Err("Codex Unix socket peer PID differs from explicit pin".into());
        }
        native_source = c
            .native_receipt_dir
            .as_ref()
            .map(|dir| crate::native_receipt::Source::connect(dir, actual_peer))
            .transpose()?;
        let generation_id = generation_for(actual_peer, native_source.is_some())
            .map_err(|e| format!("generation: {e}"))?;
        c.daemon_pid = Some(actual_peer);
        stream.set_read_timeout(Some(Duration::from_millis(20)))?;
        stream.set_write_timeout(Some(Duration::from_secs(3)))?;
        let (mut w, _) = tungstenite::client("ws://codex-app-server/rpc", stream)?;
        send(
            &mut w,
            json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"agentinbox_host","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}}),
        )?;
        ws = Some(w);
        daemon_gen = Some(generation_id);
    }
    let mut observed_claude: HashMap<String, Vec<Value>> = HashMap::new();
    let mut pending: HashMap<String, Pending> = HashMap::new();
    let mut rollouts: HashMap<String, PathBuf> = HashMap::new();
    let mut thread_contexts: HashMap<String, Value> = HashMap::new();
    let mut attached = HashSet::new();
    let mut loaded = HashSet::new();
    let mut loaded_collect = HashSet::new();
    let mut loaded_refresh = false;
    let mut queries: HashMap<u64, Option<PathBuf>> = HashMap::new();
    let mut heartbeat_at = Instant::now() - Duration::from_secs(11);
    let mut outbox_at = Instant::now();
    let mut rpc_id = 10u64;
    let mut initialized = false;
    let mut list_at = Instant::now() - Duration::from_secs(5);
    let mut poll_at = list_at;
    let drain_path = c.state_dir.join("drain");
    println!(
        "{}",
        json!({"event":"host-started","hostId":c.host_id,"runtimeId":runtime,"ipc":c.ipc_socket,"codexEnabled":ws.is_some()})
    );
    loop {
        if heartbeat_at.elapsed() > Duration::from_secs(10) {
            let _ = client::post_json(
                &c.relay_url,
                &token,
                "/v1/host/heartbeat",
                &json!({"hostId":c.host_id,"runtimeId":runtime,"draining":drain_path.exists()}),
            );
            heartbeat_at = Instant::now();
        }
        if outbox_at.elapsed() > Duration::from_secs(2) {
            if !startup_reconciled {
                startup_reconciled = reconcile_startup(&c, &token)
                    .and_then(|_| reconcile_native_dispatches(&c, &token))
                    .and_then(|_| reconcile_progress_startup(&c, &token))
                    .is_ok();
            }
            for p in pending
                .values_mut()
                .filter(|p| !p.published && p.response.is_none())
            {
                if now() < p.request["expiresAt"].as_i64().unwrap_or(0)
                    && publish(&c, &token, &p.request).is_ok()
                {
                    p.published = true;
                    println!(
                        "{}",
                        json!({"event":"request-published-after-reconnect","requestId":p.request["requestId"]})
                    );
                }
            }
            flush_receipts(&c, &token);
            outbox_at = Instant::now();
        }
        for Incoming {
            event: envelope,
            mut stream,
        } in rx.try_iter()
        {
            let mut event = envelope
                .get("hookEvent")
                .cloned()
                .unwrap_or_else(|| envelope.clone());
            if let Some(op) = event["operation"]
                .as_str()
                .filter(|op| ["status", "drain", "prepare-upgrade"].contains(op))
            {
                let mut status = json!({"draining":drain_path.exists(),"activeHooks":pending.values().filter(|p|p.hook.is_some()).count(),"submitting":pending.values().filter(|p|p.response.is_some()).count(),"activeRequests":pending.len(),"startupReconciled":startup_reconciled});
                if op != "status" {
                    if fs::write(&drain_path, b"draining\n").is_err() {
                        status["error"] = json!("cannot persist drain marker; no process stopped");
                        status["readyForUpgrade"] = json!(false);
                        status["upgradeBlockers"] = json!(["cannot persist drain marker"]);
                        let _ = writeln!(stream, "{}", status);
                        continue;
                    }
                    status["draining"] = json!(true);
                }
                if op == "prepare-upgrade" {
                    add_upgrade_readiness(&c, &token, &mut status);
                }
                // A timed-out or closed control reader must never terminate active callbacks.
                let _ = writeln!(stream, "{}", status);
                continue;
            }
            if !startup_reconciled {
                let _ = writeln!(
                    stream,
                    "{}",
                    json!({"error":"relay offline or startup reconciliation pending; use native UI"})
                );
                continue;
            }
            if drain_path.exists() {
                let _ = writeln!(
                    stream,
                    "{}",
                    json!({"error":"host draining; defer to native UI"})
                );
                continue;
            }
            let cwd = event["cwd"]
                .as_str()
                .filter(|p| Path::new(p).is_absolute())
                .and_then(|p| fs::canonicalize(p).ok());
            if !cwd
                .as_ref()
                .is_some_and(|p| p.is_dir() && c.captures_directory(p))
            {
                let _ = writeln!(
                    stream,
                    "{}",
                    json!({"error":"hook cwd outside explicit scopes"})
                );
                continue;
            }
            if !event["session_id"]
                .as_str()
                .is_some_and(|session| c.captures_session(session))
            {
                let _ = writeln!(stream, "{}", json!({"output":{}}));
                continue;
            }
            let Some(engine_runtime) = envelope["engineRuntime"].as_str() else {
                let _ = writeln!(
                    stream,
                    "{}",
                    json!({"error":"native Claude process runtime unavailable"})
                );
                continue;
            };
            let observer_key = format!(
                "{}:{}:{}",
                engine_runtime, event["session_id"], event["prompt_id"]
            );
            if event["hook_event_name"] == "PreToolUse" && event["tool_name"] != "AskUserQuestion" {
                let previous = observed_claude.entry(observer_key).or_default();
                if !previous.contains(&event) {
                    previous.push(event.clone());
                }
                let _ = writeln!(stream, "{}", json!({"output":{}}));
                continue;
            }
            if event["hook_event_name"] == "PermissionRequest" && event["tool_use_id"].is_null() {
                let matches: Vec<_> = observed_claude
                    .get(&observer_key)
                    .into_iter()
                    .flatten()
                    .filter(|e| {
                        e["tool_name"] == event["tool_name"]
                            && e["tool_input"] == event["tool_input"]
                            && !e["tool_use_id"].is_null()
                    })
                    .collect();
                if matches.len() != 1 {
                    let _ = writeln!(
                        stream,
                        "{}",
                        json!({"error":"no unique original PreToolUse binding"})
                    );
                    continue;
                }
                event["tool_use_id"] = matches[0]["tool_use_id"].clone();
            }
            let hook_deadline = envelope["deadline"].as_i64().unwrap_or(now() + 60);
            let ttl = c.request_ttl.min(hook_deadline - now());
            if ttl <= 0 {
                let _ = writeln!(stream, "{}", json!({"error":"hook deadline elapsed"}));
                continue;
            }
            let request =
                match claude::product_request(&event, &c.host_id, engine_runtime, now(), ttl) {
                    Ok(r) => r,
                    Err(e) => {
                        let _ = writeln!(stream, "{}", json!({"error":e}));
                        continue;
                    }
                };
            let key = format!("claude:{}:{}", event["session_id"], event["tool_use_id"]);
            if pending.contains_key(&key) {
                let _ = writeln!(stream, "{}", json!({"error":"duplicate native hook"}));
                continue;
            }
            if publish(&c, &token, &request).is_err() {
                let _ = writeln!(
                    stream,
                    "{}",
                    json!({"error":"relay unavailable; defer to native UI"})
                );
                continue;
            }
            pending.insert(
                key,
                Pending {
                    turn_completed: false,
                    published: true,
                    request,
                    callback: event,
                    hook: Some(stream),
                    response: None,
                    resolved: false,
                    final_text: None,
                    sent_at: None,
                    expected: None,
                    boundary: None,
                    native_source: None,
                    native_dispatch: None,
                    recorded_progress: None,
                    continuation_unknown: false,
                    blocked_receipt: None,
                },
            );
        }
        if let Some(w) = ws.as_mut() {
            if initialized
                && startup_reconciled
                && list_at.elapsed() > Duration::from_secs(2)
                && !drain_path.exists()
                && !loaded_refresh
            {
                loaded_collect.clear();
                loaded_refresh = true;
                send(
                    w,
                    json!({"id":2,"method":"thread/loaded/list","params":{"limit":100}}),
                )?;
                let scopes: Vec<Option<PathBuf>> = if c.capture_all_directories {
                    vec![None]
                } else {
                    c.scopes.iter().cloned().map(Some).collect()
                };
                for scope in scopes {
                    rpc_id += 1;
                    let params = codex_list_params(scope.as_deref(), None);
                    queries.insert(rpc_id, scope);
                    send(
                        w,
                        json!({"id":rpc_id,"method":"thread/list","params":params}),
                    )?;
                }
                list_at = Instant::now();
            }
            match w.read() {
                Ok(Message::Text(text)) => {
                    let m: Value = serde_json::from_str(&text)?;
                    if m["id"] == 1 && m.get("result").is_some() {
                        send(w, json!({"method":"initialized"}))?;
                        initialized = true;
                    }
                    if m["id"] == 2 && m.get("error").is_some() {
                        loaded_refresh = false;
                    }
                    if m["id"] == 2 && m.get("result").is_some() {
                        loaded_collect.extend(
                            m["result"]["data"]
                                .as_array()
                                .into_iter()
                                .flatten()
                                .filter_map(|v| {
                                    v.as_str().or_else(|| v["id"].as_str()).map(str::to_string)
                                }),
                        );
                        if let Some(cursor) = m["result"]["nextCursor"].as_str() {
                            send(
                                w,
                                json!({"id":2,"method":"thread/loaded/list","params":{"limit":100,"cursor":cursor}}),
                            )?;
                        } else {
                            loaded = loaded_collect.clone();
                            loaded_refresh = false;
                        }
                    }
                    if let Some(id) = m["id"]
                        .as_u64()
                        .filter(|_| m.get("result").is_some() || m.get("error").is_some())
                    {
                        if let Some(scope) = queries.remove(&id) {
                            if let Some(cursor) = m["result"]["nextCursor"].as_str() {
                                rpc_id += 1;
                                queries.insert(rpc_id, scope.clone());
                                send(
                                    w,
                                    json!({"id":rpc_id,"method":"thread/list","params":codex_list_params(scope.as_deref(),Some(cursor))}),
                                )?;
                            }
                            for t in m["result"]["data"].as_array().into_iter().flatten() {
                                let Some(tid) = t["id"].as_str() else {
                                    continue;
                                };
                                let Some(project_path) = t["cwd"]
                                    .as_str()
                                    .filter(|cwd| Path::new(cwd).is_absolute())
                                    .and_then(|cwd| fs::canonicalize(cwd).ok())
                                    .filter(|cwd| cwd.is_dir() && c.captures_directory(cwd))
                                    .filter(|cwd| scope.as_ref().is_none_or(|scope| scope == cwd))
                                else {
                                    continue;
                                };
                                if !c.captures_session(tid) {
                                    continue;
                                }
                                thread_contexts.insert(
                                    tid.to_string(),
                                    json!({"projectPath":project_path,"sessionLabel":t.get("name")}),
                                );
                                if let Some(path) = t["path"].as_str() {
                                    rollouts.insert(tid.to_string(), PathBuf::from(path));
                                }
                                let explicit = c.thread_ids.iter().any(|s| s == tid);

                                let waiting =
                                    t["status"]["activeFlags"].as_array().is_some_and(|a| {
                                        a.iter().any(|f| {
                                            f == "waitingOnUserInput" || f == "waitingOnApproval"
                                        })
                                    });
                                if loaded.contains(tid)
                                    && waiting
                                    && c.captures_session(tid)
                                    && (explicit || c.capture_loaded_native)
                                    && attached.insert(tid.to_string())
                                {
                                    println!(
                                        "{}",
                                        json!({"event":"scoped-live-attach","sessionId":tid})
                                    );
                                    rpc_id += 1;
                                    send(
                                        w,
                                        json!({"id":rpc_id,"method":"thread/resume","params":{"threadId":tid,"excludeTurns":true}}),
                                    )?;
                                }
                            }
                        }
                    }
                    if codex::is_callback(&m)
                        && m["params"]["threadId"]
                            .as_str()
                            .is_some_and(|t| attached.contains(t))
                    {
                        let key = callback_key(&m);
                        if let Some(old) = pending.get(&key) {
                            if old.callback != m {
                                let state = if old.response.is_some() {
                                    "unknown"
                                } else {
                                    "invalidated"
                                };
                                let _ = receipt(
                                    &c,
                                    &token,
                                    old,
                                    state,
                                    json!({"reason":"same native callback identity changed content; refuse cached answer"}),
                                );
                                pending.remove(&key);
                                continue;
                            }
                        }
                        if !pending.contains_key(&key) && !drain_path.exists() {
                            if let Ok(mut request) = codex::product_request(
                                &m,
                                &c.host_id,
                                daemon_gen.as_deref().unwrap(),
                                now(),
                                c.request_ttl,
                            ) {
                                if let Some(path) = m["params"]["threadId"]
                                    .as_str()
                                    .and_then(|t| rollouts.get(t))
                                {
                                    request["native"]["rolloutPath"] = json!(path);
                                }
                                if let Some(context) = m["params"]["threadId"]
                                    .as_str()
                                    .and_then(|t| thread_contexts.get(t))
                                {
                                    request["projectPath"] = context["projectPath"].clone();
                                    request["sessionLabel"] = context["sessionLabel"].clone();
                                }
                                let published = publish(&c, &token, &request);
                                if let Err(ref reason) = published {
                                    println!(
                                        "{}",
                                        json!({"event":"request-publish-rejected","reason":reason})
                                    );
                                }
                                println!(
                                    "{}",
                                    json!({"event":if published.is_ok(){"request-published"}else{"request-awaiting-relay"},"requestId":request["requestId"],"engine":"codex","sessionId":request["sessionId"]})
                                );
                                pending.insert(
                                    key,
                                    Pending {
                                        turn_completed: false,
                                        published: published.is_ok(),
                                        request,
                                        callback: m.clone(),
                                        hook: None,
                                        response: None,
                                        resolved: false,
                                        final_text: None,
                                        sent_at: None,
                                        expected: None,
                                        boundary: None,
                                        native_source: native_source.clone(),
                                        native_dispatch: None,
                                        recorded_progress: None,
                                        continuation_unknown: false,
                                        blocked_receipt: None,
                                    },
                                );
                            }
                        }
                    }
                    let mut done = Vec::new();
                    for (key, p) in &mut pending {
                        if p.request["engine"] != "codex"
                            || m["params"]["threadId"] != p.request["sessionId"]
                        {
                            continue;
                        }
                        if m["method"] == "serverRequest/resolved"
                            && m["params"]["requestId"] == p.callback["id"]
                        {
                            if p.response.is_some() {
                                p.resolved = true;
                            } else {
                                let _ = receipt(
                                    &c,
                                    &token,
                                    p,
                                    "handledLocally",
                                    json!({"native":"serverRequest/resolved before dispatch"}),
                                );
                                done.push(key.clone());
                            }
                        }
                        if m["method"] == "item/completed"
                            && m["params"]["turnId"] == p.request["turnId"]
                            && m["params"]["item"]["type"] == "agentMessage"
                        {
                            p.final_text = m["params"]["item"]["text"]
                                .as_str()
                                .map(|s| s.trim().to_string());
                        }
                        if m["method"] == "turn/completed"
                            && m["params"]["turn"]["id"] == p.request["turnId"]
                        {
                            if p.native_source.is_some() && p.response.is_some() {
                                p.turn_completed = m["params"]["turn"]["status"] == "completed";
                                p.continuation_unknown = !p.turn_completed;
                                continue;
                            }
                            let adopted = p.response.is_some()
                                && p.resolved
                                && codex_rollout_matches(p)
                                && m["params"]["turn"]["status"] == "completed";
                            if p.response.is_some()
                                && !adopted
                                && m["params"]["turn"]["status"] == "completed"
                            {
                                p.turn_completed = true;
                                continue;
                            }
                            let state = if adopted {
                                "adopted"
                            } else if p.response.is_some() {
                                "unknown"
                            } else {
                                "handledLocally"
                            };
                            if receipt(&c,&token,p,state,json!({"originalTurnCompleted":true,"nativeResolved":p.resolved,"exactAnswerEcho":p.expected.is_some()&&p.expected==p.final_text,"nativeToolResult":codex_rollout_matches(p)})).is_ok(){println!("{}",json!({"event":"request-terminal","requestId":p.request["requestId"],"state":state,"exactAnswerEcho":p.expected.is_some()&&p.expected==p.final_text,"nativeToolResult":codex_rollout_matches(p)}));done.push(key.clone());}
                        }
                    }
                    for key in done {
                        pending.remove(&key);
                    }
                }
                Ok(Message::Close(_)) | Err(tungstenite::Error::ConnectionClosed) => {
                    for p in pending.values() {
                        let _ = receipt(
                            &c,
                            &token,
                            p,
                            if p.response.is_some() {
                                "unknown"
                            } else {
                                "invalidated"
                            },
                            json!({"reason":"daemon connection closed; no replay"}),
                        );
                    }
                    return Err("daemon connection ended; restart requires fresh callbacks".into());
                }
                Err(tungstenite::Error::Io(e))
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(e) => return Err(e.into()),
                _ => {}
            }
        } else {
            thread::sleep(Duration::from_millis(50));
        }
        // A helper socket is an ephemeral callback, never a durable queue destination.
        let mut gone = Vec::new();
        for (key, p) in &mut pending {
            if p.response.is_none() {
                if let Some(stream) = p.hook.as_mut() {
                    let _ = stream.set_nonblocking(true);
                    let mut b = [0u8; 1];
                    if matches!(stream.read(&mut b), Ok(0)) {
                        let _ = receipt(
                            &c,
                            &token,
                            p,
                            "invalidated",
                            json!({"reason":"original hook exited; no dispatch"}),
                        );
                        gone.push(key.clone());
                    }
                }
            }
        }
        for key in gone {
            pending.remove(&key);
        }
        if poll_at.elapsed() > Duration::from_millis(200) {
            let request_ids: Vec<String> = pending
                .values()
                .filter(|p| p.published && p.response.is_none())
                .filter_map(|p| p.request["requestId"].as_str().map(str::to_string))
                .collect();
            for request_id in request_ids {
                if let Ok(batch) = client::get_json(
                    &c.relay_url,
                    &token,
                    &format!(
                        "/v1/host/responses?hostId={}&requestId={}",
                        c.host_id, request_id
                    ),
                ) {
                    for reply in batch["responses"].as_array().into_iter().flatten() {
                        let found = pending
                            .values_mut()
                            .find(|p| p.request["requestId"] == reply["requestId"]);
                        let Some(p) = found else {
                            let _ = client::post_json(
                                &c.relay_url,
                                &token,
                                "/v1/host/receipt",
                                &json!({"hostId":c.host_id,"requestId":reply["requestId"],"responseId":reply["responseId"],"state":"unknown","evidence":{"reason":"original live callback absent; no dispatch"}}),
                            );
                            continue;
                        };
                        if p.response.is_some() {
                            continue;
                        }
                        p.response = Some(reply.clone());
                        if now() >= p.request["expiresAt"].as_i64().unwrap_or(0) {
                            p.blocked_receipt = Some((
                                "expired".into(),
                                json!({"reason":"expired before native dispatch"}),
                            ));
                            continue;
                        }
                        let output = if p.request["engine"] == "codex" {
                            codex::response(&p.callback, &p.request, reply)
                        } else {
                            claude::output(&p.callback, &p.request, reply)
                        };
                        let mut output = match output {
                            Ok(o) => o,
                            Err(_) => {
                                p.blocked_receipt = Some((
                                    "invalidated".into(),
                                    json!({"reason":"native binding or answer validation failed"}),
                                ));
                                continue;
                            }
                        };
                        p.boundary = transcript_text(p)
                            .map(|text| crate::reply_evidence::DispatchBoundary::capture(&text));
                        p.native_dispatch = p
                            .native_source
                            .as_ref()
                            .map(|source| source.dispatch(&p.request));
                        if claim(&c, p).is_err() {
                            p.blocked_receipt = Some((
                                "unknown".into(),
                                json!({"reason":"dispatch previously claimed; no replay"}),
                            ));
                            continue;
                        }
                        if p.request["engine"] == "codex" {
                            if generation_for(c.daemon_pid.unwrap(), native_source.is_some()).ok()
                                != daemon_gen
                            {
                                p.blocked_receipt = Some((
                                    "invalidated".into(),
                                    json!({"reason":"daemon generation changed"}),
                                ));
                                continue;
                            }
                            if let Some(marker) = &c.adoption_marker {
                                if let Some(a) = output
                                    .pointer("/result/answers")
                                    .and_then(Value::as_object)
                                    .and_then(|a| a.values().next())
                                    .and_then(|a| a["answers"].as_array())
                                {
                                    p.expected = Some(format!(
                                        "{marker}{}",
                                        a.iter()
                                            .filter_map(Value::as_str)
                                            .collect::<Vec<_>>()
                                            .join(",")
                                    ));
                                }
                            }
                            if let Some(dispatch) = &p.native_dispatch {
                                output["result"]["_agentinboxReceipt"] =
                                    serde_json::to_value(dispatch)?;
                            }
                            if let Some(w) = ws.as_mut() {
                                send(w, output)?;
                            }
                        } else if let Some(mut stream) = p.hook.take() {
                            // Output delivery is NOT engine adoption. Await exact original tool_result in transcript.
                            let _ = stream.set_nonblocking(false);
                            let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
                            if writeln!(stream, "{}", json!({"output":output}))
                                .and_then(|_| stream.flush())
                                .is_err()
                            {
                                let _ = receipt(
                                    &c,
                                    &token,
                                    p,
                                    "unknown",
                                    json!({"reason":"hook delivery failed; no retry"}),
                                );
                                p.sent_at = Some(Instant::now() - Duration::from_secs(46));
                                continue;
                            }
                        }
                        p.sent_at = Some(Instant::now());
                        println!(
                            "{}",
                            json!({"event":"response-dispatched","requestId":p.request["requestId"],"responseId":reply["responseId"],"engine":p.request["engine"]})
                        );
                    }
                }
            }
            poll_at = Instant::now();
        }
        let mut done = Vec::new();
        for (key, p) in &mut pending {
            if p.blocked_receipt.is_some() {
                if settle_blocked_dispatch(&c, &token, p) {
                    done.push(key.clone());
                }
                continue;
            }
            if p.native_source.is_some() && p.response.is_some() {
                let observed = attributed_observation(p);
                let deadline = p
                    .sent_at
                    .is_some_and(|t| t.elapsed() > Duration::from_secs(45));
                if observed.received.is_some() || p.recorded_progress.is_some() {
                    if let Some(progress) =
                        progress_envelope(p, observed, deadline || p.continuation_unknown)
                    {
                        let finished = progress["continuationObservation"] != "awaiting";
                        if p.recorded_progress.as_ref() != Some(&progress) {
                            let payload = json!({"hostId":c.host_id,"requestId":p.request["requestId"],"responseId":p.response.as_ref().unwrap()["responseId"],"state":"adopted","evidence":{"native":"native arbitration and exact original function output"},"replyProgress":progress});
                            if let Ok(path) = persist_receipt(&c.state_dir, &payload) {
                                p.recorded_progress = Some(progress);
                                let _ = deliver_receipt(&c, &token, &path, payload);
                            }
                        }
                        if finished
                            && p.recorded_progress
                                .as_ref()
                                .is_some_and(|v| v["continuationObservation"] != "awaiting")
                        {
                            done.push(key.clone());
                        }
                    }
                } else if deadline {
                    let content_match = codex_rollout_matches(p);
                    if receipt(
                        &c,
                        &token,
                        p,
                        if content_match { "adopted" } else { "unknown" },
                        json!({"reason":"native source receipt missing or unverified; no replay"}),
                    )
                    .is_ok()
                    {
                        done.push(key.clone());
                    }
                }
                continue;
            }
            if p.request["engine"] == "codex"
                && p.response.is_some()
                && p.turn_completed
                && p.resolved
                && codex_rollout_matches(p)
            {
                if receipt(&c,&token,p,"adopted",json!({"native":"original turn function_call_output","exactStructuredAnswer":true})).is_ok(){println!("{}",json!({"event":"request-terminal","requestId":p.request["requestId"],"state":"adopted","nativeToolResult":true}));done.push(key.clone());}
            } else if p.request["engine"] == "claude"
                && p.response.is_some()
                && claude_tool_result_matches(p)
            {
                if receipt(
                    &c,
                    &token,
                    p,
                    "adopted",
                    json!({"native":"original tool_use_id tool_result","answerMatch":true}),
                )
                .is_ok()
                {
                    done.push(key.clone());
                }
            } else if p
                .sent_at
                .is_some_and(|t| t.elapsed() > Duration::from_secs(45))
            {
                if receipt(
                    &c,
                    &token,
                    p,
                    "unknown",
                    json!({"reason":"adoption receipt deadline; no replay"}),
                )
                .is_ok()
                {
                    done.push(key.clone());
                }
            } else if p.response.is_none() && now() >= p.request["expiresAt"].as_i64().unwrap_or(0)
            {
                if receipt(
                    &c,
                    &token,
                    p,
                    "expired",
                    json!({"reason":"native hook deadline; no approval"}),
                )
                .is_ok()
                {
                    done.push(key.clone());
                }
            }
        }
        for key in done {
            pending.remove(&key);
        }
    }
}
fn transcript_text(p: &Pending) -> Option<String> {
    let path = if p.request["engine"] == "codex" {
        p.request["native"]["rolloutPath"].as_str()
    } else {
        p.callback["transcript_path"].as_str()
    }?;
    match fs::read_to_string(path) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(String::new()),
        Err(_) => None,
    }
}
fn settle_blocked_dispatch(c: &Config, token: &str, p: &Pending) -> bool {
    let Some((state, evidence)) = &p.blocked_receipt else {
        return false;
    };
    let payload = json!({"hostId":c.host_id,"requestId":p.request["requestId"],"responseId":p.response.as_ref().map(|r|&r["responseId"]),"state":state,"evidence":evidence});
    let Ok(path) = persist_receipt(&c.state_dir, &payload) else {
        return false;
    };
    let _ = deliver_receipt(c, token, &path, payload);
    true
}
fn native_observation(p: &Pending) -> crate::reply_evidence::Observation {
    let Some(boundary) = &p.boundary else {
        return Default::default();
    };
    let Some(answer) = &p.response else {
        return Default::default();
    };
    let Some(text) = transcript_text(p) else {
        return Default::default();
    };
    crate::reply_evidence::observe(&p.request, &p.callback, answer, &text, boundary)
}
fn attributed_observation(p: &Pending) -> crate::reply_evidence::Observation {
    let (Some(source), Some(dispatch), Some(answer), Some(boundary), Some(text)) = (
        &p.native_source,
        &p.native_dispatch,
        &p.response,
        &p.boundary,
        transcript_text(p),
    ) else {
        return Default::default();
    };
    source.observe(dispatch, &p.request, &p.callback, answer, &text, boundary)
}
fn progress_envelope(
    p: &Pending,
    observation: crate::reply_evidence::Observation,
    unknown: bool,
) -> Option<Value> {
    let mut progress = if let Some(received) = observation.received {
        let mut progress = json!({"schemaVersion":1,"responseId":p.response.as_ref()?["responseId"],"bindingDigest":crate::reply_progress::binding_digest(&p.request),"received":received,"continued":observation.continued});
        for field in crate::reply_progress::IDENTITY {
            progress[*field] = p.request[*field].clone();
        }
        progress
    } else {
        p.recorded_progress.clone()?
    };
    progress["continuationObservation"] = json!(if !progress["continued"].is_null() {
        "confirmed"
    } else if unknown {
        "unknown"
    } else {
        "awaiting"
    });
    Some(progress)
}
fn claude_tool_result_matches(p: &Pending) -> bool {
    native_observation(p).received.is_some()
}
fn codex_rollout_matches(p: &Pending) -> bool {
    native_observation(p).received.is_some()
}

/// Restore only durable facts. A previous engine callback is never inherited.
pub fn reconcile_native_dispatches(c: &Config, token: &str) -> Result<(), String> {
    let Some(directory) = &c.native_receipt_dir else {
        return Ok(());
    };
    fs::canonicalize(directory).map_err(|_| "native receipt recovery source unavailable")?;
    for entry in fs::read_dir(&c.state_dir).map_err(|_| "native dispatch ledger unavailable")? {
        let entry = entry.map_err(|_| "native dispatch ledger entry unreadable")?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Some(id) = name.strip_prefix("dispatch-") else {
            continue;
        };
        if uuid::Uuid::parse_str(id).is_err() {
            continue;
        }
        let saved = crate::native_receipt::read_private(&c.state_dir, name)?;
        if saved["nativeSource"].is_null() {
            continue;
        }
        let source: crate::native_receipt::Source =
            serde_json::from_value(saved["nativeSource"].clone())
                .map_err(|_| "saved native source invalid")?;
        if saved["requestId"] != id
            || saved["request"]["requestId"] != id
            || saved["request"]["hostId"] != c.host_id
        {
            return Err("saved native dispatch context changed".into());
        }
        let dispatch = serde_json::from_value(saved["nativeDispatch"].clone())
            .map_err(|_| "saved native dispatch invalid")?;
        if saved["boundary"].is_null() {
            continue;
        }
        let boundary = serde_json::from_value(saved["boundary"].clone())
            .map_err(|_| "saved native boundary invalid")?;
        let p = Pending {
            turn_completed: false,
            published: true,
            request: saved["request"].clone(),
            callback: saved["callback"].clone(),
            hook: None,
            response: Some(saved["response"].clone()),
            resolved: false,
            final_text: None,
            sent_at: None,
            expected: None,
            boundary: Some(boundary),
            native_source: Some(source),
            native_dispatch: Some(dispatch),
            recorded_progress: None,
            continuation_unknown: true,
            blocked_receipt: None,
        };
        let observation = transcript_text(&p)
            .map(|text| {
                p.native_source.as_ref().unwrap().observe_saved(
                    p.native_dispatch.as_ref().unwrap(),
                    &p.request,
                    &p.callback,
                    p.response.as_ref().unwrap(),
                    &text,
                    p.boundary.as_ref().unwrap(),
                )
            })
            .unwrap_or_default();
        let Some(progress) = progress_envelope(&p, observation, true) else {
            continue;
        };
        let payload = json!({"hostId":c.host_id,"requestId":id,"responseId":p.response.as_ref().unwrap()["responseId"],"state":"adopted","evidence":{"reason":"read-only original native dispatch reconciliation; no replay"},"replyProgress":progress});
        let path = persist_receipt(&c.state_dir, &payload)?;
        deliver_receipt(c, token, &path, payload)?;
    }
    Ok(())
}

/// Restore only durable facts. A previous engine callback is never inherited.
pub fn reconcile_progress_startup(c: &Config, token: &str) -> Result<(), String> {
    match client::get_json(&c.relay_url, token, "/v1/capabilities") {
        Err(e) if e.starts_with("HTTP 404:") => return Ok(()),
        Ok(cap) if cap["replyProgressVersion"] == 1 => {}
        _ => return Err("relay progress capabilities unavailable".into()),
    }
    let result = client::get_json(
        &c.relay_url,
        token,
        "/v1/host/reply-progress?incomplete=true",
    )?;
    let requests = result["requests"]
        .as_array()
        .ok_or("invalid progress recovery snapshot")?;
    for q in requests {
        if q["hostId"] != c.host_id {
            return Err("progress recovery host mismatch".into());
        }
        let mut progress = q["replyProgress"].clone();
        if progress["received"].is_null() {
            return Err("incomplete record missing reception".into());
        }
        for field in crate::reply_progress::IDENTITY {
            progress[*field] = q[*field].clone();
        }
        for stage in ["received", "continued"] {
            if let Some(o) = progress[stage].as_object_mut() {
                o.remove("at");
            }
        }
        progress
            .as_object_mut()
            .ok_or("invalid progress")?
            .remove("submitted");
        progress
            .as_object_mut()
            .unwrap()
            .remove("nativeObservation");
        progress["continuationObservation"] = json!("unknown");
        let payload = json!({"hostId":c.host_id,"requestId":q["requestId"],"responseId":q["responseId"],"state":"adopted","evidence":{"reason":"host restart; original continuation not inherited"},"replyProgress":progress});
        let path = persist_receipt(&c.state_dir, &payload)?;
        deliver_receipt(c, token, &path, payload)?;
    }
    Ok(())
}

fn host_lease(host_id: &str) -> Result<fs::File, Box<dyn std::error::Error>> {
    use sha2::{Digest, Sha256};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::MetadataExt;
    unsafe extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }
    let output = Command::new("/usr/bin/id").arg("-u").output()?;
    let uid = String::from_utf8(output.stdout)?.trim().parse::<u32>()?;
    let directory = PathBuf::from("/tmp").join(format!("agentinbox-host-leases-{uid}"));
    if directory.exists() {
        let m = fs::symlink_metadata(&directory)?;
        if !m.is_dir() || m.file_type().is_symlink() || m.uid() != uid || m.mode() & 0o077 != 0 {
            return Err("host lease directory is not private and owned".into());
        }
    } else {
        private_dir(&directory)?;
    }
    let name = format!("{:x}", Sha256::digest(host_id.as_bytes()));
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(directory.join(name))?;
    // flock releases automatically on process exit; PID reuse cannot inherit the lease.
    if unsafe { flock(file.as_raw_fd(), 2 | 4) } != 0 {
        return Err("another AgentInbox host owns this hostId; no callbacks invalidated".into());
    }
    Ok(file)
}

fn archive_receipt(c: &Config, path: &Path, payload: &Value, reason: &str) -> Result<(), String> {
    let dir = c.state_dir.join("receipt-conflicts");
    private_dir(&dir).map_err(|e| e.to_string())?;
    let filename = path.file_name().ok_or("receipt file missing name")?;
    let mut archived = payload.clone();
    archived["archiveReason"] = json!(reason);
    let target = dir.join(filename);
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(target)
        .map_err(|e| e.to_string())?;
    writeln!(file, "{}", archived).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    fs::remove_file(path).map_err(|e| e.to_string())?;
    Ok(())
}
fn add_upgrade_readiness(c: &Config, token: &str, status: &mut Value) {
    let mut blockers = Vec::<&str>::new();
    if status["activeRequests"] != 0 || status["activeHooks"] != 0 || status["submitting"] != 0 {
        blockers.push("active native requests remain");
    }
    if status["startupReconciled"] != true {
        blockers.push("startup reconciliation incomplete");
    }
    let pending_receipts = match fs::read_dir(c.state_dir.join("receipt-outbox")) {
        Ok(entries) => entries
            .collect::<Result<Vec<_>, _>>()
            .ok()
            .map(|entries| entries.len()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(0),
        Err(_) => None,
    };
    match pending_receipts {
        Some(0) => {}
        Some(_) => blockers.push("durable receipts remain"),
        None => blockers.push("receipt outbox unavailable"),
    }
    status["pendingReceipts"] = json!(pending_receipts);
    status["relayOutstanding"] = Value::Null;
    if blockers.is_empty() {
        match client::get_json_bounded(
            &c.relay_url,
            token,
            "/v1/host/upgrade-status",
            Duration::from_secs(2),
        ) {
            Ok(snapshot) => {
                let count = ["pending", "submitting", "unknown"]
                    .into_iter()
                    .try_fold(0u64, |count, key| {
                        count.checked_add(snapshot[key].as_u64()?)
                    });
                if snapshot["hostId"] != c.host_id
                    || count.is_none()
                    || snapshot["awaitingContinuation"]
                        .as_u64()
                        .is_none_or(|n| snapshot["unknown"].as_u64().is_none_or(|u| u < n))
                {
                    blockers.push("relay upgrade snapshot invalid or host mismatch");
                } else {
                    status["relayOutstanding"] = json!(count);
                    if count != Some(0) {
                        blockers.push("relay has unresolved requests");
                    }
                }
            }
            Err(_) => blockers.push("authenticated relay upgrade status unavailable"),
        }
    }
    status["readyForUpgrade"] = json!(blockers.is_empty());
    status["upgradeBlockers"] = json!(blockers);
}

pub fn reconcile_startup(c: &Config, token: &str) -> Result<(), String> {
    let existing = client::get_json(&c.relay_url, token, "/v1/host/requests")?;
    let requests = existing["requests"]
        .as_array()
        .ok_or("invalid startup request snapshot")?;
    for q in requests {
        if q["hostId"] != c.host_id
            || !["codex", "claude"].contains(&q["engine"].as_str().unwrap_or(""))
            || !["pending", "submitting"].contains(&q["state"].as_str().unwrap_or(""))
        {
            continue;
        }
        let payload = json!({"hostId":c.host_id,"requestId":q["requestId"],"responseId":q.get("responseId"),"state":if q["state"]=="pending"{"invalidated"}else{"unknown"},"evidence":{"reason":"host restart; original callback cannot be inherited"}});
        let path = persist_receipt(&c.state_dir, &payload)?;
        deliver_receipt(c, token, &path, payload)?;
    }
    Ok(())
}

fn current_uid() -> u32 {
    unsafe extern "C" {
        fn getuid() -> u32;
    }
    unsafe { getuid() }
}
pub fn peer_pid(stream: &UnixStream) -> Result<u32, Box<dyn std::error::Error>> {
    use std::os::fd::AsRawFd;
    unsafe extern "C" {
        fn getsockopt(
            fd: i32,
            level: i32,
            name: i32,
            value: *mut std::ffi::c_void,
            len: *mut u32,
        ) -> i32;
    }
    #[cfg(target_os = "macos")]
    {
        let mut pid = 0i32;
        let mut len = std::mem::size_of::<i32>() as u32;
        if unsafe {
            getsockopt(
                stream.as_raw_fd(),
                0,
                2,
                &mut pid as *mut _ as *mut _,
                &mut len,
            )
        } != 0
            || pid <= 0
        {
            return Err("Unix peer PID unavailable".into());
        }
        return Ok(pid as u32);
    }
    #[cfg(target_os = "linux")]
    {
        #[repr(C)]
        struct Cred {
            pid: i32,
            uid: u32,
            gid: u32,
        }
        let mut cred = Cred {
            pid: 0,
            uid: 0,
            gid: 0,
        };
        let mut len = std::mem::size_of::<Cred>() as u32;
        if unsafe {
            getsockopt(
                stream.as_raw_fd(),
                1,
                17,
                &mut cred as *mut _ as *mut _,
                &mut len,
            )
        } != 0
            || cred.pid <= 0
        {
            return Err("Unix peer PID unavailable".into());
        }
        return Ok(cred.pid as u32);
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        Err("Unix peer PID unsupported on this platform".into())
    }
}

fn peer_uid(stream: &UnixStream) -> Result<u32, Box<dyn std::error::Error>> {
    use std::os::fd::AsRawFd;
    #[cfg(target_os = "macos")]
    {
        unsafe extern "C" {
            fn getpeereid(fd: i32, uid: *mut u32, gid: *mut u32) -> i32;
        }
        let mut uid = 0u32;
        let mut gid = 0u32;
        if unsafe { getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
            return Err("Unix peer UID unavailable".into());
        }
        return Ok(uid);
    }
    #[cfg(target_os = "linux")]
    {
        unsafe extern "C" {
            fn getsockopt(
                fd: i32,
                level: i32,
                name: i32,
                value: *mut std::ffi::c_void,
                len: *mut u32,
            ) -> i32;
        }
        #[repr(C)]
        struct Cred {
            pid: i32,
            uid: u32,
            gid: u32,
        }
        let mut cred = Cred {
            pid: 0,
            uid: 0,
            gid: 0,
        };
        let mut len = std::mem::size_of::<Cred>() as u32;
        if unsafe {
            getsockopt(
                stream.as_raw_fd(),
                1,
                17,
                &mut cred as *mut _ as *mut _,
                &mut len,
            )
        } != 0
        {
            return Err("Unix peer UID unavailable".into());
        }
        return Ok(cred.uid);
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        Err("Unix peer UID unsupported".into())
    }
}

#[cfg(test)]
mod codex_rollout_provenance_tests {
    use super::*;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};

    struct Fixture {
        directory: PathBuf,
        pending: Pending,
    }

    impl Fixture {
        fn phone_beta() -> Self {
            let directory = std::env::temp_dir().join(format!(
                "AgentInboxConcurrencyProvenance-{}",
                uuid::Uuid::new_v4()
            ));
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .unwrap();
            let callback = json!({
                "id": 42,
                "method": "item/tool/requestUserInput",
                "params": {
                    "threadId": "original-session",
                    "turnId": "original-turn",
                    "itemId": "original-call",
                    "questions": [{
                        "id": "route",
                        "header": "Route",
                        "question": "Isolated provenance fixture",
                        "options": [{"label": "Alpha"}, {"label": "Beta"}]
                    }]
                }
            });
            let mut request =
                codex::product_request(&callback, "fixture-host", "fixture-runtime", 100, 600)
                    .unwrap();
            request["native"]["rolloutPath"] = json!(directory.join("original.jsonl"));
            let response = json!({
                "requestId": request["requestId"],
                "responseId": "phone-beta",
                "revision": request["revision"],
                "optionIds": ["q0-o1"]
            });
            Self {
                directory,
                pending: Pending {
                    turn_completed: true,
                    published: true,
                    request,
                    callback,
                    hook: None,
                    response: Some(response),
                    resolved: true,
                    final_text: None,
                    sent_at: None,
                    expected: None,
                    boundary: Some(crate::reply_evidence::DispatchBoundary::capture("")),
                    native_source: None,
                    native_dispatch: None,
                    recorded_progress: None,
                    continuation_unknown: false,
                    blocked_receipt: None,
                },
            }
        }

        fn write_result(&self, session: &str, turn: &str, call: &str, answer: &str) {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(self.directory.join("original.jsonl"))
                .unwrap();
            for row in [
                json!({"type": "session_meta", "payload": {"id": session}}),
                json!({"type": "event_msg", "payload": {
                    "type": "task_started", "turn_id": turn
                }}),
                json!({"type": "response_item", "payload": {
                    "type": "function_call_output",
                    "call_id": call,
                    "output": json!({"answers": {"route": {"answers": [answer]}}}).to_string()
                }}),
            ] {
                writeln!(file, "{row}").unwrap();
            }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_file(self.directory.join("original.jsonl"));
            let _ = fs::remove_dir(&self.directory);
        }
    }

    #[test]
    fn failed_pre_dispatch_preparation_durably_settles_without_waiting_for_native_output() {
        let mut fixture = Fixture::phone_beta();
        fixture.pending.blocked_receipt = Some((
            "expired".into(),
            json!({"reason":"expired before native dispatch"}),
        ));
        let c:Config=serde_json::from_value(json!({"hostId":"fixture-host","relayUrl":"http://127.0.0.1:0","tokenFile":fixture.directory.join("fixture-key"),"stateDir":fixture.directory,"ipcSocket":fixture.directory.join("hook.sock"),"scopes":[fixture.directory]})).unwrap();
        assert!(settle_blocked_dispatch(
            &c,
            "public-fixture-key-not-a-credential",
            &fixture.pending
        ));
        let entries = fs::read_dir(fixture.directory.join("receipt-outbox"))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(entries.len(), 1);
        let receipt: Value = serde_json::from_slice(&fs::read(entries[0].path()).unwrap()).unwrap();
        assert_eq!(receipt["state"], "expired");
        assert!(receipt.get("replyProgress").is_none());
        assert!(
            !fixture
                .directory
                .join(format!(
                    "dispatch-{}",
                    fixture.pending.request["requestId"].as_str().unwrap()
                ))
                .exists()
        );
        fs::remove_dir_all(fixture.directory.join("receipt-outbox")).unwrap();
    }

    #[test]
    fn transient_observation_gap_preserves_received_and_active_wait_until_deadline() {
        let mut fixture = Fixture::phone_beta();
        let observed = crate::reply_evidence::Observation {
            received: Some(
                json!({"proofId":"fixture-proof","kind":"codex.function_call_output","sourceDigest":"a".repeat(64),"position":3}),
            ),
            continued: None,
        };
        let first = progress_envelope(&fixture.pending, observed, false).unwrap();
        fixture.pending.recorded_progress = Some(first.clone());
        let gap = progress_envelope(&fixture.pending, Default::default(), false).unwrap();
        assert_eq!(gap["received"], first["received"]);
        assert_eq!(
            gap["continuationObservation"], "awaiting",
            "temporary read/partial row must keep the observer active"
        );
        let deadline = progress_envelope(&fixture.pending, Default::default(), true).unwrap();
        assert_eq!(deadline["received"], first["received"]);
        assert_eq!(deadline["continuationObservation"], "unknown");
    }

    #[test]
    fn original_local_alpha_does_not_match_phone_beta() {
        let fixture = Fixture::phone_beta();
        fixture.write_result(
            "original-session",
            "original-turn",
            "original-call",
            "Alpha",
        );
        assert!(!codex_rollout_matches(&fixture.pending));
    }

    #[test]
    fn exact_original_beta_matches_phone_beta() {
        let fixture = Fixture::phone_beta();
        fixture.write_result("original-session", "original-turn", "original-call", "Beta");
        assert!(codex_rollout_matches(&fixture.pending));
    }

    #[test]
    fn other_session_beta_does_not_match_phone_beta() {
        let fixture = Fixture::phone_beta();
        fixture.write_result("other-session", "original-turn", "original-call", "Beta");
        assert!(!codex_rollout_matches(&fixture.pending));
    }

    #[test]
    fn other_turn_beta_does_not_match_phone_beta() {
        let fixture = Fixture::phone_beta();
        fixture.write_result("original-session", "other-turn", "original-call", "Beta");
        assert!(!codex_rollout_matches(&fixture.pending));
    }

    #[test]
    fn other_call_beta_does_not_match_phone_beta() {
        let fixture = Fixture::phone_beta();
        fixture.write_result("original-session", "original-turn", "other-call", "Beta");
        assert!(!codex_rollout_matches(&fixture.pending));
    }
}
