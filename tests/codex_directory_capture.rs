use agentinbox::host::Config;
use serde_json::{Value, json};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    os::unix::{
        fs::{PermissionsExt, symlink},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
use tungstenite::{Message, WebSocket};

fn config_json() -> Value {
    json!({"hostId":"directory-fixture","relayUrl":"http://127.0.0.1:0","tokenFile":"/unused/public-fixture","stateDir":"/unused/state","ipcSocket":"/unused/hook.sock","scopes":[],"threadIds":[]})
}

#[test]
fn legacy_configuration_defaults_to_scoped_directory_capture() {
    let config: Config = serde_json::from_value(config_json()).unwrap();
    assert_eq!(
        serde_json::to_value(config).unwrap()["captureAllDirectories"],
        false,
        "legacy JSON must explicitly default captureAllDirectories to false"
    );
}

// The socket belongs to this real child process. Its executable path satisfies the
// production managed-daemon generation check; no peer PID or UID is substituted.
#[test]
#[ignore = "native daemon child entry point; spawned only by Fixture"]
fn codex_mock_daemon() {
    let root = PathBuf::from(std::env::var_os("AINB_CODEX_FIXTURE_ROOT").expect("fixture root"));
    let listener = UnixListener::bind(root.join("codex.sock")).unwrap();
    listener.set_nonblocking(true).unwrap();
    let deadline = Instant::now() + Duration::from_secs(25);
    let stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < deadline, "no fixture host connected");
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => panic!("accept: {error}"),
        }
    };
    // Darwin may inherit the listener's nonblocking flag on accepted sockets.
    // The synchronous handshake needs a blocking stream with a bounded timeout.
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut ws = tungstenite::accept(stream).unwrap();
    ws.get_mut()
        .set_read_timeout(Some(Duration::from_millis(50)))
        .unwrap();
    let mut log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("rpc.jsonl"))
        .unwrap();
    while Instant::now() < deadline {
        let message = match ws.read() {
            Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).unwrap(),
            Ok(_) => continue,
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(_) => break,
        };
        writeln!(log, "{message}").unwrap();
        log.flush().unwrap();
        match message["method"].as_str() {
            Some("initialize") => send(
                &mut ws,
                json!({"id":message["id"],"result":{"userAgent":"isolated-native-fixture"}}),
            ),
            Some("initialized") => {
                // A callback alone must never attach an excluded or unlisted session.
                send(&mut ws, callback("old-outside"));
                send(&mut ws, callback("unlisted-old"));
            }
            Some("thread/loaded/list") if root.join("loaded-error").exists() => send(
                &mut ws,
                json!({"id":message["id"],"error":{"code":-1,"message":"fixture loaded scan failure"}}),
            ),
            Some("thread/loaded/list") => send(
                &mut ws,
                json!({"id":message["id"],"result":{"data":["old-scoped","old-outside","new-scoped","new-child","new-outside","not-waiting"],"nextCursor":null}}),
            ),
            Some("thread/list") => {
                let (data, cursor) = if message["params"].get("cursor").is_none() {
                    (
                        vec![
                            native_thread(&root, "old-scoped", "scope", true),
                            native_thread(&root, "new-scoped", "scope", true),
                        ],
                        json!("fixture-page-two"),
                    )
                } else {
                    (
                        vec![
                            native_thread(&root, "old-outside", "outside", true),
                            native_thread(&root, "new-child", "scope/child", true),
                            native_thread(&root, "new-outside", "outside", true),
                            native_thread(&root, "not-waiting", "outside", false),
                            native_thread(&root, "not-loaded", "outside", true),
                        ],
                        Value::Null,
                    )
                };
                send(
                    &mut ws,
                    json!({"id":message["id"],"result":{"data":data,"nextCursor":cursor}}),
                );
            }
            Some("thread/resume") => {
                send(&mut ws, json!({"id":message["id"],"result":{}}));
                send(
                    &mut ws,
                    callback(message["params"]["threadId"].as_str().unwrap()),
                );
            }
            _ => {}
        }
    }
}
fn send(ws: &mut WebSocket<UnixStream>, value: Value) {
    ws.send(Message::Text(value.to_string())).unwrap();
}
fn callback(id: &str) -> Value {
    json!({"id":format!("callback-{id}"),"method":"item/tool/requestUserInput","params":{"threadId":id,"turnId":"fixture-turn","itemId":format!("item-{id}"),"questions":[{"id":"route","header":"Route","question":"Isolated directory capture fixture","options":[{"label":"Alpha"},{"label":"Beta"}]}]}})
}
fn native_thread(root: &Path, id: &str, directory: &str, waiting: bool) -> Value {
    json!({"id":id,"cwd":fs::canonicalize(root.join(directory)).unwrap(),"name":format!("Fixture {id}"),"status":{"type":"active","activeFlags":if waiting {json!(["waitingOnUserInput"])} else {json!([])}}})
}

struct Fixture {
    root: PathBuf,
    host: Option<Child>,
    daemon: Option<Child>,
    published: Arc<Mutex<Vec<Value>>>,
    stop: Arc<AtomicBool>,
    relay: Option<thread::JoinHandle<()>>,
}
impl Fixture {
    fn new(all: Option<bool>) -> Self {
        Self::with_loaded_error(all, false)
    }
    fn with_loaded_error(all: Option<bool>, loaded_error: bool) -> Self {
        let root = PathBuf::from("/tmp").join(format!(
            "ainb-cdx-{}",
            &uuid::Uuid::new_v4().to_string()[..8]
        ));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let mut fixture = Self {
            root,
            host: None,
            daemon: None,
            published: Arc::new(Mutex::new(Vec::new())),
            stop: Arc::new(AtomicBool::new(false)),
            relay: None,
        };
        fs::create_dir_all(fixture.root.join("scope/child")).unwrap();
        fs::create_dir(fixture.root.join("outside")).unwrap();
        if loaded_error {
            fs::write(fixture.root.join("loaded-error"), b"fixture").unwrap();
        }
        let executable = fixture.root.join("app-server--managed-daemon");
        symlink(std::env::current_exe().unwrap(), &executable).unwrap();
        let daemon_log = fs::File::create(fixture.root.join("daemon.log")).unwrap();
        fixture.daemon = Some(
            Command::new(executable)
                .args(["--ignored", "--exact", "codex_mock_daemon", "--nocapture"])
                .env("AINB_CODEX_FIXTURE_ROOT", &fixture.root)
                .stdout(Stdio::null())
                .stderr(daemon_log)
                .spawn()
                .unwrap(),
        );
        fixture.wait_for("native socket", |f| f.root.join("codex.sock").exists());
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}", server.server_addr().to_ip().unwrap());
        let writes = fixture.published.clone();
        let heartbeat_file = fixture.root.join("diagnostic-heartbeats.jsonl");
        let stop = fixture.stop.clone();
        fixture.relay = Some(thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                if let Some(mut request) = server.recv_timeout(Duration::from_millis(20)).unwrap() {
                    let body = if request.method().as_str() == "POST"
                        && request.url() == "/v1/host/requests"
                    {
                        let value: Value = serde_json::from_reader(request.as_reader()).unwrap();
                        writes.lock().unwrap().push(value.clone());
                        value
                    } else if request.url() == "/v1/host/heartbeat" {
                        let value: Value = serde_json::from_reader(request.as_reader()).unwrap();
                        let mut out = OpenOptions::new()
                            .create(true)
                            .append(true)
                            .open(&heartbeat_file)
                            .unwrap();
                        writeln!(out, "{}", value["diagnostics"]).unwrap();
                        json!({})
                    } else if request.url() == "/v1/capabilities" {
                        json!({"replyProgressVersion":1,"bindingDigestVersion":1})
                    } else if request.url().starts_with("/v1/host/reply-progress") {
                        json!({"requests":[]})
                    } else if request.url() == "/v1/host/requests" {
                        json!({"requests":[]})
                    } else if request.url().starts_with("/v1/host/responses") {
                        json!({"responses":[]})
                    } else {
                        json!({})
                    };
                    let _ = request.respond(tiny_http::Response::from_string(body.to_string()));
                }
            }
        }));
        let token = fixture.root.join("public-fixture-token");
        fs::write(&token, "public-directory-capture-fixture").unwrap();
        fs::set_permissions(&token, fs::Permissions::from_mode(0o600)).unwrap();
        let state = fixture.root.join("state");
        let mut config = config_json();
        config["hostId"] = json!(format!("directory-fixture-{}", uuid::Uuid::new_v4()));
        config["relayUrl"] = json!(url);
        config["tokenFile"] = json!(token);
        config["stateDir"] = json!(state);
        config["ipcSocket"] = json!(state.join("ipc/hook.sock"));
        config["codexSocket"] = json!(fixture.root.join("codex.sock"));
        config["daemonPid"] = json!(fixture.daemon.as_ref().unwrap().id());
        config["scopes"] = json!([fs::canonicalize(fixture.root.join("scope")).unwrap()]);
        config["threadIds"] = json!(["old-scoped", "old-outside"]);
        config["excludedSessionIds"] = json!(["old-scoped", "old-outside"]);
        config["captureLoadedNative"] = json!(true);
        if let Some(all) = all {
            config["captureAllDirectories"] = json!(all);
        }
        let path = fixture.root.join("host.json");
        fs::write(&path, config.to_string()).unwrap();
        let stderr = fs::File::create(fixture.root.join("host.log")).unwrap();
        fixture.host = Some(
            Command::new(env!("CARGO_BIN_EXE_agentinbox"))
                .args(["host", path.to_str().unwrap()])
                .stdout(Stdio::null())
                .stderr(stderr)
                .spawn()
                .unwrap(),
        );
        fixture.wait_for("paginated native discovery and scoped publication", |f| {
            f.rpc().iter().any(|m| {
                m["method"] == "thread/list" && m["params"]["cursor"] == "fixture-page-two"
            }) && (loaded_error
                || f.published
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|r| r["sessionId"] == "new-scoped"))
        });
        fixture
    }
    fn rpc(&self) -> Vec<Value> {
        fs::read_to_string(self.root.join("rpc.jsonl"))
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect()
    }
    fn wait_for(&mut self, label: &str, condition: impl Fn(&Self) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(12);
        while !condition(self) {
            let daemon_pid = self.daemon.as_ref().unwrap().id().to_string();
            for (name, child) in [("host", &mut self.host), ("daemon", &mut self.daemon)] {
                if let Some(child) = child {
                    assert!(
                        child.try_wait().unwrap().is_none(),
                        "fixture {name} exited; {}; daemon={}; ps={:?}",
                        fs::read_to_string(self.root.join("host.log")).unwrap_or_default(),
                        fs::read_to_string(self.root.join("daemon.log")).unwrap_or_default(),
                        Command::new("/bin/ps")
                            .args(["-p", &daemon_pid, "-o", "lstart=", "-o", "command="])
                            .output()
                    );
                }
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {label}; RPC={:?}",
                self.rpc()
            );
            thread::sleep(Duration::from_millis(20));
        }
    }
    fn resumed(&self) -> Vec<String> {
        let mut ids: Vec<_> = self
            .rpc()
            .iter()
            .filter(|m| m["method"] == "thread/resume")
            .map(|m| m["params"]["threadId"].as_str().unwrap().to_string())
            .collect();
        ids.sort();
        ids
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        for child in [&mut self.host, &mut self.daemon] {
            if let Some(child) = child {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        self.stop.store(true, Ordering::SeqCst);
        if let Some(relay) = self.relay.take() {
            let _ = relay.join();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn all_directories_discovers_pages_without_cwd_and_keeps_excluded_sessions_native() {
    let mut fixture = Fixture::new(Some(true));
    let lists: Vec<_> = fixture
        .rpc()
        .into_iter()
        .filter(|m| m["method"] == "thread/list")
        .collect();
    assert!(lists.len() >= 2, "global discovery must paginate");
    for request in lists {
        assert!(
            request["params"].get("cwd").is_none(),
            "captureAllDirectories must omit cwd on initial and paginated thread/list: {request}"
        );
        assert_eq!(request["params"]["useStateDbOnly"], true);
    }
    fixture.wait_for("new sessions in child and unrelated directories", |f| {
        f.published.lock().unwrap().len() >= 3
    });
    assert_eq!(
        fixture.resumed(),
        ["new-child", "new-outside", "new-scoped"],
        "excluded pinned sessions, inactive sessions and unloaded sessions must never attach"
    );
    let requests = fixture.published.lock().unwrap();
    let mut ids: Vec<_> = requests
        .iter()
        .map(|r| r["sessionId"].as_str().unwrap())
        .collect();
    ids.sort();
    assert_eq!(
        ids,
        ["new-child", "new-outside", "new-scoped"],
        "excluded and unsolicited old callbacks must never publish"
    );
    for request in requests.iter() {
        let directory = match request["sessionId"].as_str().unwrap() {
            "new-child" => "scope/child",
            "new-outside" => "outside",
            _ => "scope",
        };
        assert_eq!(
            request["projectPath"],
            json!(fs::canonicalize(fixture.root.join(directory)).unwrap())
        );
    }
}

#[test]
fn omitted_or_false_all_directories_keeps_exact_scopes_on_every_page() {
    for all in [None, Some(false)] {
        let mut fixture = Fixture::new(all);
        // A subsequent refresh proves the host processed the previous page before
        // negative assertions; this does not depend on a scheduling delay.
        fixture.wait_for("second discovery refresh", |f| {
            f.rpc()
                .iter()
                .filter(|m| m["method"] == "thread/list" && m["params"].get("cursor").is_none())
                .count()
                >= 2
        });
        let lists: Vec<_> = fixture
            .rpc()
            .into_iter()
            .filter(|m| m["method"] == "thread/list")
            .collect();
        assert!(lists.len() >= 2);
        let scope = json!(fs::canonicalize(fixture.root.join("scope")).unwrap());
        for request in lists {
            assert_eq!(request["params"]["cwd"], scope);
        }
        assert_eq!(
            fixture.resumed(),
            ["new-scoped"],
            "scopes are exact: descendants and unrelated directories remain native"
        );
        let requests = fixture.published.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0]["sessionId"], "new-scoped");
    }
}

#[test]
fn failed_loaded_thread_discovery_cannot_report_successful_capture() {
    let mut f = Fixture::with_loaded_error(Some(true), true);
    f.wait_for("second diagnostic heartbeat", |f| {
        fs::read_to_string(f.root.join("diagnostic-heartbeats.jsonl"))
            .unwrap_or_default()
            .lines()
            .count()
            >= 2
    });
    let text = fs::read_to_string(f.root.join("diagnostic-heartbeats.jsonl")).unwrap();
    let observation: Value = serde_json::from_str(text.lines().last().unwrap()).unwrap();
    assert!(
        observation["scanAt"].is_null(),
        "Successful thread/list cannot mask failed loaded-thread discovery"
    );
    assert!(f.published.lock().unwrap().is_empty());
}
