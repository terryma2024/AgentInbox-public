use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

struct Fixture {
    binary: PathBuf,
    root: PathBuf,
    socket: PathBuf,
    host_id: String,
    host: Child,
    snapshot: Arc<Mutex<(u16, Value)>>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
impl Fixture {
    fn new() -> Self {
        let binary = std::env::var_os("AGENTINBOX_TEST_BINARY")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_agentinbox")));
        let root = PathBuf::from("/tmp").join(format!(
            "ainb-upgrade-{}",
            &uuid::Uuid::new_v4().to_string()[..8]
        ));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let token = root.join("public-fixture-token");
        fs::write(&token, "public-upgrade-test-fixture-token").unwrap();
        fs::set_permissions(&token, fs::Permissions::from_mode(0o600)).unwrap();
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}", server.server_addr().to_ip().unwrap());
        let host_id = format!("upgrade-fixture-{}", uuid::Uuid::new_v4());
        let snapshot = Arc::new(Mutex::new((
            200,
            json!({"hostId":host_id,"pending":0,"submitting":0,"unknown":0,"awaitingContinuation":0}),
        )));
        let stop = Arc::new(AtomicBool::new(false));
        let data = snapshot.clone();
        let done = stop.clone();
        let worker = thread::spawn(move || {
            while !done.load(Ordering::SeqCst) {
                if let Some(req) = server.recv_timeout(Duration::from_millis(20)).unwrap() {
                    let (status, body) = if req.url() == "/v1/host/upgrade-status" {
                        data.lock().unwrap().clone()
                    } else if req.url() == "/v1/capabilities" {
                        (
                            200,
                            json!({"replyProgressVersion":1,"bindingDigestVersion":1}),
                        )
                    } else if req.url().starts_with("/v1/host/reply-progress") {
                        (200, json!({"requests":[]}))
                    } else if req.url() == "/v1/host/requests" {
                        (200, json!({"requests":[]}))
                    } else {
                        (200, json!({}))
                    };
                    let _ = req.respond(
                        tiny_http::Response::from_string(body.to_string()).with_status_code(status),
                    );
                }
            }
        });
        let state = root.join("state");
        let socket = state.join("ipc/hook.sock");
        let config = root.join("host.json");
        fs::write(&config, json!({"hostId":host_id,"relayUrl":url,"tokenFile":token,"stateDir":state,"ipcSocket":socket,"scopes":[root],"threadIds":[],"requestTtl":60}).to_string()).unwrap();
        let host = Command::new(&binary)
            .args(["host", config.to_str().unwrap()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut fixture = Self {
            binary,
            root,
            socket,
            host_id,
            host,
            snapshot,
            stop,
            worker: Some(worker),
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                fixture.host.try_wait().unwrap().is_none(),
                "fixture host exited during startup"
            );
            if fixture.socket.exists() {
                let out = fixture.control("status");
                if out.status.success()
                    && serde_json::from_slice::<Value>(&out.stdout).unwrap()["startupReconciled"]
                        == true
                {
                    break;
                }
            }
            assert!(
                Instant::now() < deadline,
                "fixture host did not become ready"
            );
            thread::sleep(Duration::from_millis(20));
        }
        fixture
    }
    fn control(&self, op: &str) -> std::process::Output {
        Command::new(&self.binary)
            .args(["hostctl", self.socket.to_str().unwrap(), op])
            .output()
            .unwrap()
    }
    fn guard(&self, success: bool) -> Value {
        let out = self.control("prepare-upgrade");
        assert_eq!(
            out.status.success(),
            success,
            "unexpected control result: stdout={} stderr={}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let value: Value =
            serde_json::from_slice(&out.stdout).expect("structured upgrade readiness output");
        assert_eq!(value["readyForUpgrade"], success);
        assert_eq!(value["draining"], true);
        value
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.host.kill();
        let _ = self.host.wait();
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn upgrade_requires_drain_settled_relay_and_empty_durable_receipts() {
    let mut fixture = Fixture::new();
    let ready = fixture.guard(true);
    assert_eq!(ready["relayOutstanding"], 0);
    assert!(fixture.root.join("state/drain").exists());
    // Draining must immediately hand new helpers back to the native UI.
    let mut s = UnixStream::connect(&fixture.socket).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    writeln!(s,"{}",json!({"hookEvent":{"cwd":fixture.root},"helperPid":std::process::id(),"engineRuntime":"explicit-test-fixture"})).unwrap();
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line).unwrap();
    assert!(line.contains("host draining"));
    *fixture.snapshot.lock().unwrap() = (
        200,
        json!({"hostId":fixture.host_id,"pending":0,"submitting":0,"unknown":1,"awaitingContinuation":1}),
    );
    assert_eq!(fixture.guard(false)["relayOutstanding"], 1);
    // A lost native adoption receipt remains unsafe even with no in-memory callbacks.
    *fixture.snapshot.lock().unwrap() = (
        200,
        json!({"hostId":fixture.host_id,"pending":0,"submitting":0,"unknown":1,"awaitingContinuation":0}),
    );
    assert_eq!(fixture.guard(false)["relayOutstanding"], 1);
    *fixture.snapshot.lock().unwrap() = (503, json!({"error":"fixture relay offline"}));
    fixture.guard(false);
    *fixture.snapshot.lock().unwrap() = (
        200,
        json!({"hostId":fixture.host_id,"pending":"bad snapshot"}),
    );
    fixture.guard(false);
    *fixture.snapshot.lock().unwrap() = (
        200,
        json!({"hostId":"another-host","pending":0,"submitting":0,"unknown":0,"awaitingContinuation":0}),
    );
    fixture.guard(false);
    *fixture.snapshot.lock().unwrap() = (
        200,
        json!({"hostId":fixture.host_id,"pending":-1,"submitting":0,"unknown":0,"awaitingContinuation":0}),
    );
    fixture.guard(false);
    *fixture.snapshot.lock().unwrap() = (
        200,
        json!({"hostId":fixture.host_id,"pending":0,"submitting":0,"unknown":0,"awaitingContinuation":0}),
    );
    let outbox = fixture.root.join("state/receipt-outbox");
    fs::create_dir_all(&outbox).unwrap();
    fs::set_permissions(&outbox, fs::Permissions::from_mode(0o700)).unwrap();
    let receipt = outbox.join("interrupted-receipt.json");
    fs::write(&receipt, b"{}").unwrap();
    assert_eq!(fixture.guard(false)["pendingReceipts"], 1);
    fs::remove_file(&receipt).unwrap();
    fixture.guard(true);
    assert!(
        fixture.host.try_wait().unwrap().is_none(),
        "readiness checks must never stop host"
    );
}

#[test]
fn abandoned_control_client_does_not_crash_host_or_drop_callbacks() {
    let mut fixture = Fixture::new();
    let mut stream = UnixStream::connect(&fixture.socket).unwrap();
    stream.shutdown(std::net::Shutdown::Read).unwrap();
    writeln!(stream, "{}", json!({"operation":"drain"})).unwrap();
    drop(stream);
    // The marker proves this exact abandoned event entered the host loop before
    // checking liveness, regardless of listener thread order.
    let deadline = Instant::now() + Duration::from_secs(3);
    while !fixture.root.join("state/drain").exists() {
        assert!(
            fixture.host.try_wait().unwrap().is_none(),
            "host exited processing the closed control reader"
        );
        assert!(
            Instant::now() < deadline,
            "closed-reader drain was never processed"
        );
        thread::yield_now();
    }
    let out = fixture.control("status");
    assert!(
        out.status.success(),
        "host must survive a disconnected control reader: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(fixture.host.try_wait().unwrap().is_none());
}

#[test]
fn failed_drain_marker_write_defers_upgrade_without_stopping_host() {
    let mut fixture = Fixture::new();
    let marker = fixture.root.join("state/drain");
    fs::create_dir(&marker).unwrap();
    let out = fixture.control("prepare-upgrade");
    assert!(!out.status.success());
    let status: Value = serde_json::from_slice(&out.stdout)
        .expect("failed drain write must return structured refusal");
    assert_eq!(status["readyForUpgrade"], false);
    assert!(
        fixture.host.try_wait().unwrap().is_none(),
        "failed control operation must not terminate host"
    );
    assert!(fixture.control("status").status.success());
    fs::remove_dir(marker).unwrap();
}
