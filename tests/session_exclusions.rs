use agentinbox::host::Config;
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

fn config_json() -> Value {
    json!({"hostId":"session-fixture","relayUrl":"http://127.0.0.1:0","tokenFile":"/unused/public-fixture","stateDir":"/unused/state","ipcSocket":"/unused/hook.sock","scopes":[],"threadIds":[]})
}

#[test]
fn legacy_configuration_defaults_to_no_session_exclusions() {
    let config: Config = serde_json::from_value(config_json()).unwrap();
    assert!(config.captures_session("existing-session"));
    assert!(config.captures_session("new-session"));
    assert!(!config.captures_session(""));
    assert!(!config.captures_session("   "));
    assert_eq!(
        serde_json::to_value(config).unwrap()["excludedSessionIds"],
        json!([])
    );
}

#[test]
fn explicit_thread_pin_preserves_session_exclusion_configuration() {
    let mut value = config_json();
    value["threadIds"] = json!(["old-session"]);
    value["excludedSessionIds"] = json!(["old-session"]);
    let config: Config = serde_json::from_value(value).unwrap();
    assert!(config.thread_ids.iter().any(|id| id == "old-session"));
    assert!(
        !config.captures_session("old-session"),
        "an explicit thread pin must not override exclusion"
    );
    assert!(config.captures_session("new-session"));
    assert_eq!(
        serde_json::to_value(config).unwrap()["excludedSessionIds"],
        json!(["old-session"])
    );
}

struct Fixture {
    root: PathBuf,
    socket: PathBuf,
    host: Child,
    published: Arc<Mutex<Vec<Value>>>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}

impl Fixture {
    fn new() -> Self {
        Self::with_directory_policy(false, false)
    }
    fn with_directory_policy(all: bool, empty_scopes: bool) -> Self {
        let root = PathBuf::from("/tmp").join(format!(
            "ainb-sessions-{}",
            &uuid::Uuid::new_v4().to_string()[..8]
        ));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let token = root.join("public-fixture-token");
        fs::write(&token, "public-session-exclusion-fixture").unwrap();
        fs::set_permissions(&token, fs::Permissions::from_mode(0o600)).unwrap();
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}", server.server_addr().to_ip().unwrap());
        let published = Arc::new(Mutex::new(Vec::new()));
        let writes = published.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let finished = stop.clone();
        let worker = thread::spawn(move || {
            while !finished.load(Ordering::SeqCst) {
                if let Some(mut request) = server.recv_timeout(Duration::from_millis(20)).unwrap() {
                    let body = if request.method().as_str() == "POST"
                        && request.url() == "/v1/host/requests"
                    {
                        let value: Value = serde_json::from_reader(request.as_reader()).unwrap();
                        writes.lock().unwrap().push(value.clone());
                        value
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
        });
        let state = root.join("state");
        let socket = state.join("ipc/hook.sock");
        let mut config = config_json();
        config["hostId"] = json!(format!("session-fixture-{}", uuid::Uuid::new_v4()));
        config["relayUrl"] = json!(url);
        config["tokenFile"] = json!(token);
        config["stateDir"] = json!(state);
        config["ipcSocket"] = json!(socket);
        config["scopes"] = if empty_scopes {
            json!([])
        } else {
            json!([root])
        };
        config["captureAllDirectories"] = json!(all);
        config["excludedSessionIds"] = json!(["existing-session"]);
        let config_path = root.join("host.json");
        fs::write(&config_path, config.to_string()).unwrap();
        let host = Command::new(env!("CARGO_BIN_EXE_agentinbox"))
            .args(["host", config_path.to_str().unwrap()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut fixture = Self {
            root,
            socket,
            host,
            published,
            stop,
            worker: Some(worker),
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                fixture.host.try_wait().unwrap().is_none(),
                "fixture host exited"
            );
            if fixture.socket.exists() && fixture.status()["startupReconciled"] == true {
                break;
            }
            assert!(Instant::now() < deadline, "fixture host was not ready");
            thread::sleep(Duration::from_millis(20));
        }
        fixture
    }
    fn status(&self) -> Value {
        let mut stream = UnixStream::connect(&self.socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        writeln!(stream, "{}", json!({"operation":"status"})).unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }
    fn hook(&self, event: Value) -> UnixStream {
        let mut stream = UnixStream::connect(&self.socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        writeln!(stream, "{}", json!({"hookEvent":event,"engineRuntime":"isolated-fixture-runtime","deadline":agentinbox::host::now()+30})).unwrap();
        stream
    }
    fn returned_to_native(&self, event: Value) {
        let stream = self.hook(event);
        let mut line = String::new();
        let read = BufReader::new(stream).read_line(&mut line);
        assert!(
            read.is_ok(),
            "excluded hook must promptly return to native UI: {read:?}"
        );
        assert_eq!(
            serde_json::from_str::<Value>(&line).unwrap(),
            json!({"output":{}})
        );
    }
    fn question(&self, session: &str) -> Value {
        json!({"cwd":self.root,"session_id":session,"prompt_id":"prompt","tool_use_id":format!("question-{session}"),"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Isolated session exclusion fixture","header":"Choice","multiSelect":false,"options":[{"label":"Alpha"},{"label":"Beta"}]}]}})
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
fn excluded_claude_question_never_publishes_but_new_session_still_does() {
    let fixture = Fixture::new();
    fixture.returned_to_native(fixture.question("existing-session"));
    assert!(fixture.published.lock().unwrap().is_empty());
    assert_eq!(fixture.status()["activeRequests"], 0);
    let _new_hook = fixture.hook(fixture.question("new-session"));
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if !fixture.published.lock().unwrap().is_empty() {
            break;
        }
        assert!(Instant::now() < deadline, "new session did not publish");
        thread::sleep(Duration::from_millis(20));
    }
    let requests = fixture.published.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0]["sessionId"], "new-session");
    assert_eq!(fixture.status()["activeRequests"], 1);
}

#[test]
fn excluded_claude_observer_and_permission_hook_return_empty_without_publish() {
    let fixture = Fixture::new();
    let event = json!({"cwd":fixture.root,"session_id":"existing-session","prompt_id":"prompt","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"existing-tool","tool_input":{"command":"printf fixture"}});
    fixture.returned_to_native(event.clone());
    let mut permission = event;
    permission["hook_event_name"] = json!("PermissionRequest");
    permission.as_object_mut().unwrap().remove("tool_use_id");
    fixture.returned_to_native(permission);
    assert!(fixture.published.lock().unwrap().is_empty());
    assert_eq!(fixture.status()["activeHooks"], 0);
}

#[test]
fn missing_or_empty_claude_session_returns_native_without_publish() {
    let fixture = Fixture::new();
    let mut missing = fixture.question("unused");
    missing.as_object_mut().unwrap().remove("session_id");
    fixture.returned_to_native(missing);
    fixture.returned_to_native(fixture.question(""));
    assert!(fixture.published.lock().unwrap().is_empty());
}

#[test]
fn all_directory_capture_is_explicit_and_defaults_off() {
    let legacy: Config = serde_json::from_value(config_json()).unwrap();
    assert_eq!(
        serde_json::to_value(legacy).unwrap()["captureAllDirectories"],
        false
    );
    let mut value = config_json();
    value["captureAllDirectories"] = json!(true);
    let enabled: Config = serde_json::from_value(value).unwrap();
    assert_eq!(
        serde_json::to_value(enabled).unwrap()["captureAllDirectories"],
        true
    );
}

#[test]
fn all_directory_mode_captures_a_real_unlisted_directory() {
    let fixture = Fixture::with_directory_policy(true, false);
    let outside = fixture.root.join("unlisted");
    fs::create_dir(&outside).unwrap();
    let mut event = fixture.question("new-unlisted-session");
    event["cwd"] = json!(outside);
    let _hook = fixture.hook(event);
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if !fixture.published.lock().unwrap().is_empty() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "all-directory mode did not capture unlisted cwd"
        );
        thread::sleep(Duration::from_millis(20));
    }
    let published = fixture.published.lock().unwrap();
    assert_eq!(published.len(), 1);
    assert_eq!(
        published[0]["projectPath"],
        outside.to_string_lossy().as_ref()
    );
    assert_eq!(published[0]["sessionId"], "new-unlisted-session");
}

#[test]
fn all_directory_mode_does_not_override_old_session_exclusion() {
    let fixture = Fixture::with_directory_policy(true, false);
    let outside = fixture.root.join("unlisted");
    fs::create_dir(&outside).unwrap();
    let mut event = fixture.question("existing-session");
    event["cwd"] = json!(outside);
    fixture.returned_to_native(event);
    assert!(fixture.published.lock().unwrap().is_empty());
    assert_eq!(fixture.status()["activeRequests"], 0);
}

#[test]
fn explicit_all_directory_mode_can_start_with_no_scopes() {
    let fixture = Fixture::with_directory_policy(true, true);
    assert_eq!(fixture.status()["startupReconciled"], true);
}

#[test]
fn default_directory_policy_still_rejects_an_unlisted_directory() {
    let fixture = Fixture::new();
    let outside = fixture.root.join("unlisted");
    fs::create_dir(&outside).unwrap();
    let mut event = fixture.question("new-session");
    event["cwd"] = json!(outside);
    let mut line = String::new();
    BufReader::new(fixture.hook(event))
        .read_line(&mut line)
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&line).unwrap()["error"],
        "hook cwd outside explicit scopes"
    );
    assert!(fixture.published.lock().unwrap().is_empty());
}
