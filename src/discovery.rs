//! Optional, read-only product discovery. This endpoint never grants product access.
use serde::Serialize;
use std::net::{IpAddr, SocketAddr};
use tiny_http::{Header, Response, Server};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveryInfo {
    product: &'static str,
    protocol_version: u32,
    schema_version: u32,
    host_id: String,
    host_name: String,
    os: &'static str,
    version: &'static str,
    #[serde(rename = "relayURL")]
    relay_url: String,
}

fn tailnet_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.octets()[0] == 100 && (64..128).contains(&ip.octets()[1]),
        IpAddr::V6(ip) => ip.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
    }
}

impl DiscoveryInfo {
    pub fn new(host_id: &str, host_name: &str, relay_url: &str) -> Result<Self, String> {
        let url = reqwest::Url::parse(relay_url).map_err(|_| "invalid discovery relay URL")?;
        let host = url.host_str().ok_or("discovery relay host required")?;
        let ip = host.trim_matches(['[', ']']).parse::<IpAddr>().ok();
        if host_id.is_empty()
            || host_name.is_empty()
            || host_id.len() > 256
            || host_name.len() > 256
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || url.path() != "/"
            || host == "localhost"
            || ip.is_some_and(|ip| ip.is_loopback() || ip.is_unspecified())
            || !(url.scheme() == "https"
                || (url.scheme() == "http"
                    && (ip.is_some_and(tailnet_ip) || host.ends_with(".ts.net"))))
        {
            return Err("discovery requires a non-loopback HTTPS or Tailscale relay origin without credentials, path or query".into());
        }
        Ok(Self {
            product: "agentinbox",
            protocol_version: 1,
            schema_version: 1,
            host_id: host_id.into(),
            host_name: host_name.into(),
            os: std::env::consts::OS,
            version: env!("CARGO_PKG_VERSION"),
            relay_url: relay_url.trim_end_matches('/').into(),
        })
    }
}

pub fn bind(address: &str) -> Result<Server, String> {
    let address: SocketAddr = address
        .parse()
        .map_err(|_| "discovery listen must be an IP:port")?;
    if !address.ip().is_loopback() && !tailnet_ip(address.ip()) {
        return Err("discovery may only listen on loopback or a Tailscale IP".into());
    }
    Server::http(address).map_err(|_| "unable to bind discovery listener".into())
}

pub fn serve_one(server: &Server, info: &DiscoveryInfo) -> std::io::Result<()> {
    let request = server.recv()?;
    let (status, body) = if request.url() != "/v1/discovery" {
        (404, "{}".to_string())
    } else if request.method() != &tiny_http::Method::Get {
        (405, "{}".to_string())
    } else {
        (200, serde_json::to_string(info)?)
    };
    request.respond(
        Response::from_string(body)
            .with_status_code(status)
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap())
            .with_header(Header::from_bytes("Cache-Control", "no-store").unwrap()),
    )
}

pub fn start_from_args(
    args: &[String],
    host_id: &str,
) -> Result<Option<(Server, DiscoveryInfo)>, String> {
    for option in ["--discovery-listen", "--discovery-relay-url"] {
        let positions = args
            .iter()
            .enumerate()
            .filter(|(_, arg)| arg.as_str() == option)
            .map(|(i, _)| i)
            .collect::<Vec<_>>();
        if positions.len() > 1
            || positions
                .first()
                .is_some_and(|i| args.get(i + 1).is_none_or(|value| value.starts_with("--")))
        {
            return Err(format!("{option} requires exactly one value"));
        }
    }
    let listen = args.windows(2).find(|w| w[0] == "--discovery-listen");
    let relay = args.windows(2).find(|w| w[0] == "--discovery-relay-url");
    match (listen, relay) {
        (None, None) => Ok(None),
        (Some(listen), Some(relay)) => {
            let hostname = std::process::Command::new("hostname")
                .output()
                .map_err(|_| "hostname unavailable")?;
            if !hostname.status.success() {
                return Err("hostname unavailable".into());
            }
            let name = String::from_utf8_lossy(&hostname.stdout);
            let info = DiscoveryInfo::new(host_id, name.trim(), &relay[1])?;
            Ok(Some((bind(&listen[1])?, info)))
        }
        _ => Err("--discovery-listen and --discovery-relay-url must be supplied together".into()),
    }
}
