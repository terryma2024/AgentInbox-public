use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixListener,
    process::{Command, Stdio},
    time::{Duration, Instant},
};
#[test]
fn unavailable_host_does_not_approve() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_agentinbox"))
        .args(["hook", "/tmp/agentinbox-nonexistent-fixture-socket", "5"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    writeln!(child.stdin.take().unwrap(),"{}",json!({"hook_event_name":"PermissionRequest","session_id":"fixture-session","tool_name":"Bash","tool_use_id":"fixture-item"})).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&out.stdout).unwrap(),
        json!({})
    );
}
#[test]
fn timeout_deadline_is_bounded_and_never_allows() {
    let root = std::path::PathBuf::from("/tmp").join(format!(
        "ainb-helper-{}",
        &uuid::Uuid::new_v4().to_string()[..8]
    ));
    fs::create_dir_all(&root).unwrap();
    let socket = root.join("hook.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let (s, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(&s).read_line(&mut line).unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        assert!(v["deadline"].as_i64().unwrap() <= agentinbox::host::now() + 5);
        assert!(v["helperPid"].is_number());
        std::thread::sleep(Duration::from_secs(6));
    });
    let start = Instant::now();
    let mut child = Command::new(env!("CARGO_BIN_EXE_agentinbox"))
        .args(["hook", socket.to_str().unwrap(), "5"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    writeln!(child.stdin.take().unwrap(),"{}",json!({"hook_event_name":"PermissionRequest","session_id":"fixture","tool_use_id":"fixture-item"})).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&out.stdout).unwrap(),
        json!({})
    );
    assert!(start.elapsed() < Duration::from_secs(7));
    server.join().unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn duplicate_host_id_is_rejected_before_reconciling_any_callbacks() {
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    let root = std::path::PathBuf::from("/tmp").join(format!(
        "ainb-lease-{}",
        &uuid::Uuid::new_v4().to_string()[..8]
    ));
    fs::create_dir_all(&root).unwrap();
    let token = root.join("public-fixture-token");
    fs::write(&token, "public-test-token-not-a-secret").unwrap();
    fs::set_permissions(&token, fs::Permissions::from_mode(0o600)).unwrap();
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}", server.server_addr().to_ip().unwrap());
    let stopped = Arc::new(AtomicBool::new(false));
    let calls = Arc::new(AtomicUsize::new(0));
    let thread_stop = stopped.clone();
    let thread_calls = calls.clone();
    let worker = std::thread::spawn(move || {
        while !thread_stop.load(Ordering::SeqCst) {
            if let Some(q) = server.recv_timeout(Duration::from_millis(100)).unwrap() {
                thread_calls.fetch_add(1, Ordering::SeqCst);
                q.respond(tiny_http::Response::from_string(
                    json!({"requests":[]}).to_string(),
                ))
                .unwrap();
            }
        }
    });
    let host_id = format!("fixture-{}", uuid::Uuid::new_v4());
    let make_config = |name: &str| {
        let state = root.join(name);
        json!({"hostId":host_id,"relayUrl":url,"tokenFile":token,"stateDir":state,"ipcSocket":state.join("ipc/hook.sock"),"scopes":[root],"threadIds":[],"requestTtl":60})
    };
    let first_config = root.join("first.json");
    let second_config = root.join("second.json");
    fs::write(&first_config, make_config("first-state").to_string()).unwrap();
    fs::write(&second_config, make_config("second-state").to_string()).unwrap();
    let mut first = Command::new(env!("CARGO_BIN_EXE_agentinbox"))
        .args(["host", first_config.to_str().unwrap()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !root.join("first-state/ipc/hook.sock").exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(root.join("first-state/ipc/hook.sock").exists());
    std::thread::sleep(Duration::from_millis(100));
    let calls_before_second = calls.load(Ordering::SeqCst);
    let second = Command::new(env!("CARGO_BIN_EXE_agentinbox"))
        .args(["host", second_config.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!second.status.success());
    assert!(
        String::from_utf8_lossy(&second.stderr)
            .contains("another AgentInbox host owns this hostId")
    );
    assert_eq!(
        calls.load(Ordering::SeqCst),
        calls_before_second,
        "second host must not reconcile first host's requests"
    );
    // A different hostId cannot unlink the first host's active socket either.
    let mut active_config = make_config("first-state");
    active_config["hostId"] = json!(format!("different-{}", uuid::Uuid::new_v4()));
    let active_path = root.join("active-conflict.json");
    fs::write(&active_path, active_config.to_string()).unwrap();
    let active = Command::new(env!("CARGO_BIN_EXE_agentinbox"))
        .args(["host", active_path.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!active.status.success());
    assert!(String::from_utf8_lossy(&active.stderr).contains("IPC has an active owner"));
    first.kill().unwrap();
    first.wait().unwrap();
    // Crash leaves the socket file but releases the kernel lease; restart safely replaces it.
    let mut restarted = Command::new(env!("CARGO_BIN_EXE_agentinbox"))
        .args(["host", first_config.to_str().unwrap()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut restarted_connected = false;
    while Instant::now() < deadline {
        if std::os::unix::net::UnixStream::connect(root.join("first-state/ipc/hook.sock")).is_ok() {
            restarted_connected = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        restarted_connected,
        "crashed host must recover its stale private socket"
    );
    restarted.kill().unwrap();
    restarted.wait().unwrap();
    stopped.store(true, Ordering::SeqCst);
    worker.join().unwrap();
    fs::remove_dir_all(root).unwrap();
}
