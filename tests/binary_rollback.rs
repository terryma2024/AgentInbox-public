//! Explicit previous/current native-binary compatibility drill; no real Agent or credentials.
use reqwest::blocking::Client;
use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    net::TcpListener,
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
const DEVICE: &str = "rollback-public-device-fixture-0001";
const HOST: &str = "rollback-public-host-fixture-0001";
struct Drill {
    root: PathBuf,
    base: String,
    client: Client,
    relay: Option<Child>,
    host: Option<Child>,
    host_id: String,
    current: PathBuf,
    previous: PathBuf,
}
impl Drill {
    fn new() -> Self {
        let root = PathBuf::from("/tmp").join(format!(
            "ainb-rollback-{}",
            &uuid::Uuid::new_v4().to_string()[..8]
        ));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let host_id = format!("rollback-fixture-{}", uuid::Uuid::new_v4());
        fs::write(root.join("relay.json"),json!({"listen":format!("127.0.0.1:{port}"),"database":root.join("inbox.sqlite"),"credentials":[{"id":"fixture-device","role":"device","token":DEVICE},{"id":"fixture-host","role":"host","hostId":host_id,"token":HOST}],"apns":null}).to_string()).unwrap();
        let token = root.join("public-fixture-token");
        fs::write(&token, HOST).unwrap();
        fs::set_permissions(&token, fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(root.join("host.json"),json!({"hostId":host_id,"relayUrl":format!("http://127.0.0.1:{port}"),"tokenFile":token,"stateDir":root.join("state"),"ipcSocket":root.join("state/ipc/hook.sock"),"scopes":[root],"threadIds":[],"requestTtl":60}).to_string()).unwrap();
        Self {
            root,
            base: format!("http://127.0.0.1:{port}"),
            client: Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(2))
                .build()
                .unwrap(),
            relay: None,
            host: None,
            host_id,
            current: std::env::var_os("AGENTINBOX_TEST_BINARY")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_agentinbox"))),
            previous: PathBuf::from(
                std::env::var_os("AGENTINBOX_PREVIOUS_BINARY")
                    .expect("explicit previous native binary required"),
            ),
        }
    }
    fn start_relay(&mut self, previous: bool) {
        let binary = if previous {
            &self.previous
        } else {
            &self.current
        };
        self.relay = Some(
            Command::new(binary)
                .args(["relay", "--config"])
                .arg(self.root.join("relay.json"))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                self.relay.as_mut().unwrap().try_wait().unwrap().is_none(),
                "native relay failed to start"
            );
            if self
                .client
                .get(format!("{}/v1/requests", self.base))
                .bearer_auth(DEVICE)
                .send()
                .is_ok_and(|r| r.status().is_success())
            {
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    fn call(&self, token: &str, path: &str, body: Option<Value>) -> (u16, Value) {
        let req = match body {
            Some(v) => self.client.post(format!("{}{}", self.base, path)).json(&v),
            None => self.client.get(format!("{}{}", self.base, path)),
        };
        let r = req.bearer_auth(token).send().unwrap();
        (r.status().as_u16(), r.json().unwrap())
    }
    fn start_host(&mut self) {
        self.host = Some(
            Command::new(&self.current)
                .arg("host")
                .arg(self.root.join("host.json"))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                self.host.as_mut().unwrap().try_wait().unwrap().is_none(),
                "native host failed to start"
            );
            if self.root.join("state/ipc/hook.sock").exists() {
                if let Ok(mut socket) = UnixStream::connect(self.root.join("state/ipc/hook.sock")) {
                    socket
                        .set_read_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    writeln!(socket, "{}", json!({"operation":"status"})).unwrap();
                    let mut line = String::new();
                    if BufReader::new(socket).read_line(&mut line).is_ok()
                        && serde_json::from_str::<Value>(&line)
                            .is_ok_and(|v| v["startupReconciled"] == true)
                    {
                        break;
                    }
                }
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    fn prepare(&self, expected: bool) -> Value {
        let out = Command::new(&self.current)
            .arg("hostctl")
            .arg(self.root.join("state/ipc/hook.sock"))
            .arg("prepare-upgrade")
            .output()
            .unwrap();
        assert_eq!(
            out.status.success(),
            expected,
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let value: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(value["readyForUpgrade"], expected);
        assert_eq!(value["activeRequests"], 0);
        assert_eq!(value["activeHooks"], 0);
        assert_eq!(value["submitting"], 0);
        value
    }
    fn stop_host(&mut self) {
        if let Some(mut child) = self.host.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    fn stop_relay(&mut self) {
        if let Some(mut child) = self.relay.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
impl Drop for Drill {
    fn drop(&mut self) {
        self.stop_host();
        self.stop_relay();
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn digest(path: &Path) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(fs::read(path).unwrap())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

#[test]
#[ignore = "explicit previous native binary required; run dedicated rollback drill"]
fn native_binary_rollback_preserves_answers_and_old_relay_blocks_new_guard() {
    let mut d = Drill::new();
    d.start_relay(false);
    let request_id = "rollback-adopted-fixture";
    let response_id = "rollback-stable-response";
    let request = json!({"requestId":request_id,"hostId":d.host_id,"engine":"codex","runtimeId":"SIMULATED-ROLLBACK-ENGINE","sessionId":"simulated-rollback-session","turnId":"simulated-rollback-turn","nativeRequestId":"simulated-native-request","itemId":"simulated-item","revision":1,"expiresAt":agentinbox::model::now()+600,"kind":"choice","title":"隔离回滚测试","body":"公开模拟题，不是原生Agent采用证明","options":[{"id":"beta","label":"Beta"}],"multiSelect":false,"native":{"explicitSimulation":true}});
    assert_eq!(d.call(HOST, "/v1/host/requests", Some(request)).0, 200);
    let response = json!({"requestId":request_id,"responseId":response_id,"revision":1,"optionIds":["beta"],"text":null,"answers":{}});
    assert_eq!(
        d.call(
            DEVICE,
            &format!("/v1/requests/{request_id}/responses"),
            Some(response.clone())
        )
        .0,
        200
    );
    assert_eq!(
        d.call(
            HOST,
            &format!("/v1/host/responses?requestId={request_id}"),
            None
        )
        .1["responses"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(d.call(HOST,"/v1/host/receipt",Some(json!({"requestId":request_id,"responseId":response_id,"state":"adopted","evidence":{"explicitSimulatedEngineResult":true}}))).0,200);
    d.start_host();
    let before = d.prepare(true);
    d.stop_host();
    d.stop_relay();
    // Reopen the same database with the exact sealed previous native binary.
    d.start_relay(true);
    let old_read = d.call(DEVICE, &format!("/v1/requests/{request_id}"), None);
    assert_eq!(old_read.0, 200);
    assert_eq!(old_read.1["state"], "adopted");
    assert_eq!(old_read.1["responseId"], response_id);
    assert_eq!(
        d.call(
            DEVICE,
            &format!("/v1/requests/{request_id}/responses"),
            Some(response.clone())
        )
        .1["state"],
        "adopted"
    );
    assert!(
        d.call(
            HOST,
            &format!("/v1/host/responses?requestId={request_id}"),
            None
        )
        .1["responses"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    d.start_host();
    let old_peer = d.prepare(false);
    assert!(
        old_peer["upgradeBlockers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v.as_str().unwrap().contains("unavailable"))
    );
    assert!(d.host.as_mut().unwrap().try_wait().unwrap().is_none());
    // Test-resource cleanup is allowed because all native callback counts are zero.
    d.stop_host();
    d.stop_relay();
    d.start_relay(false);
    d.start_host();
    let restored = d.prepare(true);
    assert_eq!(
        d.call(
            DEVICE,
            &format!("/v1/requests/{request_id}/responses"),
            Some(response)
        )
        .1["state"],
        "adopted"
    );
    assert!(
        d.call(
            HOST,
            &format!("/v1/host/responses?requestId={request_id}"),
            None
        )
        .1["responses"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let proof = json!({"scope":"actual old/new isolated native binaries, explicitly simulated engine result","currentBinarySHA256":digest(&d.current),"previousBinarySHA256":digest(&d.previous),"hostId":d.host_id,"requestId":request_id,"responseId":response_id,"beforeRollback":before,"oldRelayGuardRefusal":old_peer,"afterReupgrade":restored,"sameDatabasePreserved":true,"adoptedResponseIdPreserved":true,"duplicateAnswerRemainedIdempotent":true,"newClaimCountAfterRollback":0,"installedServicesChanged":false,"realAgentOrPhoneUsed":false});
    if let Some(path) = std::env::var_os("AGENTINBOX_ROLLBACK_EVIDENCE") {
        fs::write(path, serde_json::to_vec_pretty(&proof).unwrap()).unwrap();
    }
}
