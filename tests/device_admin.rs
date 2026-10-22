//! Local native operator tests. All identities/DBs/keys are disposable fixtures, never deployed credentials.
use agentinbox::{model::now, store::Store};
use p256::{
    ecdsa::SigningKey,
    pkcs8::{EncodePrivateKey, LineEnding},
};
use reqwest::blocking::Client;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    net::TcpListener,
    os::unix::fs::{OpenOptionsExt, PermissionsExt, symlink},
    path::PathBuf,
    process::{Child, Command, Output, Stdio},
    time::{Duration, Instant},
};

const HOST: &str = "public-isolated-admin-host-fixture";
struct Fixture {
    root: PathBuf,
    db: PathBuf,
    child: Option<Child>,
    base: String,
    client: Client,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("ainb-admin-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let db = root.join("inbox.sqlite");
        drop(Store::open(&db).unwrap());
        fs::set_permissions(&db, fs::Permissions::from_mode(0o600)).unwrap();
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        Self {
            root,
            db,
            child: None,
            base: format!("http://127.0.0.1:{port}"),
            client: Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(4))
                .build()
                .unwrap(),
        }
    }
    fn start(&mut self, apns: Value, proxy: Option<String>) {
        let config = json!({"listen":self.base.trim_start_matches("http://"),"database":self.db,"credentials":[{"id":"fixture-host","role":"host","hostId":"h","token":HOST}],"apns":apns});
        let path = self.root.join("relay.json");
        fs::write(&path, config.to_string()).unwrap();
        let mut command = Command::new(env!("CARGO_BIN_EXE_agentinbox"));
        command
            .args(["relay", "--config"])
            .arg(path)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Some(proxy) = proxy {
            for key in [
                "HTTP_PROXY",
                "http_proxy",
                "HTTPS_PROXY",
                "https_proxy",
                "ALL_PROXY",
                "all_proxy",
            ] {
                command.env(key, &proxy);
            }
            command.env("NO_PROXY", "").env("no_proxy", "");
        }
        self.child = Some(command.spawn().unwrap());
        for _ in 0..60 {
            if self.call_try(HOST, "/v1/hosts", None).is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(40));
        }
        panic!("isolated relay startup failed");
    }
    fn call_try(&self, key: &str, path: &str, body: Option<Value>) -> Option<(u16, Value)> {
        let builder = if let Some(v) = body {
            self.client.post(format!("{}{path}", self.base)).json(&v)
        } else {
            self.client.get(format!("{}{path}", self.base))
        };
        let response = builder.bearer_auth(key).send().ok()?;
        let status = response.status().as_u16();
        Some((status, response.json().ok()?))
    }
    fn call(&self, key: &str, path: &str, body: Option<Value>) -> (u16, Value) {
        self.call_try(key, path, body)
            .expect("fixture HTTP unavailable")
    }
    fn admin(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_agentinbox"))
            .arg("device-admin")
            .arg(&self.db)
            .args(args)
            .output()
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn question(id: &str) -> Value {
    json!({"requestId":id,"revision":1,"expiresAt":now()+600,"kind":"choice","hostId":"h","engine":"codex","runtimeId":"fixture-runtime","sessionId":format!("session-{id}"),"turnId":"turn","nativeRequestId":id,"itemId":id,"title":"隔离","body":"选择","options":[{"id":"a","label":"甲"}],"multiSelect":false})
}
fn pair(store: &Store, code: &str, name: &str) -> Value {
    store.add_pair_code(code, now()).unwrap();
    store.pair(code, name, now()).unwrap()
}
fn request_snapshot(db: &Connection) -> (String, String, i64, String) {
    db.query_row("SELECT q.state,r.id,r.claimed,r.json FROM requests q JOIN responses r ON r.request=q.id WHERE q.id='claimed'",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).unwrap()
}
fn revocation_snapshot(db: &Connection, id: &str) -> (i64, i64, i64, String) {
    db.query_row("SELECT c.revoked,d.active,(SELECT COUNT(*) FROM revoked_credentials WHERE id=c.id),(SELECT group_concat(state,',') FROM outbox WHERE device=c.id) FROM device_credentials c JOIN devices d ON c.id=d.id WHERE c.id=?1",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).unwrap()
}

#[test]
fn native_operator_revokes_lost_paired_key_online_without_recovery_or_other_identity_changes() {
    let mut f = Fixture::new();
    {
        let s = Store::open(&f.db).unwrap();
        s.add_pair_code("fixture-code-lost", now()).unwrap();
        s.add_pair_code("fixture-code-second", now()).unwrap();
    }
    f.start(Value::Null, None);
    let pid = f.child.as_ref().unwrap().id();
    let first = f
        .call(
            "",
            "/v1/pair",
            Some(json!({"code":"fixture-code-lost","name":"lost fixture phone"})),
        )
        .1;
    let second = f
        .call(
            "",
            "/v1/pair",
            Some(json!({"code":"fixture-code-second","name":"other fixture phone"})),
        )
        .1;
    let id = first["deviceId"].as_str().unwrap();
    let token = first["token"].as_str().unwrap();
    let other = second["token"].as_str().unwrap();
    for (key, t) in [(token, "a".repeat(64)), (other, "b".repeat(64))] {
        assert_eq!(
            f.call(
                key,
                "/v1/devices/token",
                Some(json!({"token":t,"environment":"sandbox"}))
            )
            .0,
            200
        );
    }
    for q in ["claimed", "push-pending"] {
        assert_eq!(f.call(HOST, "/v1/host/requests", Some(question(q))).0, 200);
    }
    assert_eq!(f.call(token,"/v1/requests/claimed/responses",Some(json!({"requestId":"claimed","responseId":"original-response","revision":1,"optionIds":["a"],"text":null,"answers":{}}))).0,200);
    assert_eq!(
        f.call(HOST, "/v1/host/responses?requestId=claimed", None).1["responses"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let db = Connection::open(&f.db).unwrap();
    let before = request_snapshot(&db);
    assert_eq!(before.0, "submitting");
    let list = f.admin(&["list"]);
    assert!(
        list.status.success(),
        "native operator list is missing or failed"
    );
    let text = String::from_utf8(list.stdout).unwrap();
    let metadata: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(metadata["devices"].as_array().unwrap().len(), 2);
    for secret in [
        "hash",
        "token",
        token,
        other,
        &"a".repeat(64),
        &"b".repeat(64),
    ] {
        assert!(
            !text.contains(secret),
            "operator metadata leaked a credential field/value"
        );
    }
    assert_eq!(
        request_snapshot(&db),
        before,
        "list must not invoke recovery"
    );
    let revoked = f.admin(&["revoke", id]);
    assert!(
        revoked.status.success(),
        "native operator revoke is missing or failed"
    );
    assert_eq!(f.call(token, "/v1/requests", None).0, 401);
    assert_eq!(
        f.call(
            token,
            "/v1/devices/token",
            Some(json!({"token":"c".repeat(64),"environment":"sandbox"}))
        )
        .0,
        401
    );
    assert_eq!(f.call(other, "/v1/hosts", None).0, 200);
    assert_eq!(f.call(HOST, "/v1/host/requests", None).0, 200);
    assert_eq!(f.call(HOST, "/v1/devices/revoke", Some(json!({}))).0, 403);
    assert_eq!(
        request_snapshot(&db),
        before,
        "operator must not flip claimed request to unknown or change response"
    );
    assert_eq!(f.child.as_ref().unwrap().id(), pid);
    assert!(f.child.as_mut().unwrap().try_wait().unwrap().is_none());
    assert_eq!(
        revocation_snapshot(&db, id),
        (1, 0, 1, "cancelled,cancelled".into())
    );
    assert!(
        f.admin(&["revoke", id]).status.success(),
        "repeat revocation should be idempotent"
    );
    let list: Value = serde_json::from_slice(&f.admin(&["list"]).stdout).unwrap();
    let lost = list["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["deviceId"] == id)
        .unwrap();
    assert_eq!(lost["revoked"], true);
    assert_eq!(lost["pushActive"], false);
}

#[test]
fn cancellation_failure_rolls_back_all_revocation_writes_for_self_and_operator() {
    for operator in [false, true] {
        let f = Fixture::new();
        let s = Store::open(&f.db).unwrap();
        let device = pair(&s, "fixture-rollback-code", "fixture");
        let id = device["deviceId"].as_str().unwrap();
        s.device_token(id, &"a".repeat(64), "sandbox").unwrap();
        s.create("h", question("pending"), now()).unwrap();
        let db = Connection::open(&f.db).unwrap();
        db.execute_batch("CREATE TRIGGER fixture_fail_cancel BEFORE UPDATE OF state ON outbox WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'fixture final cancellation failure'); END;").unwrap();
        let before = revocation_snapshot(&db, id);
        if operator {
            assert!(!f.admin(&["revoke", id]).status.success());
        } else {
            assert!(s.revoke_device(id).is_err());
        }
        assert_eq!(
            revocation_snapshot(&db, id),
            before,
            "final-step failure must roll back credential, revocation marker, active flag, outbox together"
        );
        assert!(
            s.device_credential(device["token"].as_str().unwrap())
                .unwrap()
                .is_some()
        );
    }
}

#[test]
fn operator_rejects_missing_wrong_schema_unknown_device_and_unsafe_paths_without_creation() {
    let f = Fixture::new();
    let missing = f.root.join("missing.sqlite");
    let invoke = |path: &std::path::Path, args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_agentinbox"))
            .arg("device-admin")
            .arg(path)
            .args(args)
            .output()
            .unwrap()
    };
    assert!(!invoke(&missing, &["list"]).status.success());
    assert!(
        !invoke(&missing, &["revoke", "device-unknown"])
            .status
            .success()
    );
    assert!(!missing.exists());
    let wrong = f.root.join("wrong.sqlite");
    {
        let db = Connection::open(&wrong).unwrap();
        db.execute_batch("CREATE TABLE untouched(x);INSERT INTO untouched VALUES(7);")
            .unwrap();
    }
    fs::set_permissions(&wrong, fs::Permissions::from_mode(0o600)).unwrap();
    let before = fs::read(&wrong).unwrap();
    assert!(!invoke(&wrong, &["list"]).status.success());
    assert!(
        !invoke(&wrong, &["revoke", "device-unknown"])
            .status
            .success()
    );
    assert_eq!(fs::read(&wrong).unwrap(), before);
    assert!(!f.admin(&["revoke", "device-unknown"]).status.success());
    assert!(!f.admin(&["revoke", "../bad"]).status.success());
    let db = Connection::open(&f.db).unwrap();
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM revoked_credentials", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    let link = f.root.join("linked.sqlite");
    symlink(&f.db, &link).unwrap();
    assert!(!invoke(&link, &["list"]).status.success());
    assert!(
        !invoke(&link, &["revoke", "device-unknown"])
            .status
            .success()
    );
    fs::set_permissions(&f.db, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(!f.admin(&["list"]).status.success());
    assert!(!f.admin(&["revoke", "device-unknown"]).status.success());
    fs::set_permissions(&f.db, fs::Permissions::from_mode(0o600)).unwrap();
    assert!(
        f.admin(&["list"]).status.success(),
        "valid private existing schema should be listable"
    );
}

#[test]
fn fetched_push_batch_cancelled_by_revocation_cannot_be_resurrected_by_late_results() {
    for (ok, permanent) in [(true, false), (false, false), (false, true)] {
        let f = Fixture::new();
        let s = Store::open(&f.db).unwrap();
        let d = pair(&s, "fixture-late-result-code", "fixture");
        let id = d["deviceId"].as_str().unwrap();
        s.device_token(id, &"a".repeat(64), "sandbox").unwrap();
        s.create("h", question("q"), now()).unwrap();
        let batch = s.push_batch(now()).unwrap();
        assert_eq!(batch.len(), 1);
        let job = batch[0]["id"].as_i64().unwrap();
        assert!(s.push_job_authorized(job, now()).unwrap());
        assert!(
            !s.push_job_authorized(job, now() + 1000).unwrap(),
            "expired original request cannot authorize a fetched job"
        );
        s.revoke_device(id).unwrap();
        assert!(
            !s.push_job_authorized(job, now()).unwrap(),
            "revoked fetched job must fail the dispatch predicate"
        );
        assert!(s.push_batch(now()).unwrap().is_empty());
        let db = Connection::open(&f.db).unwrap();
        let before: (String, i64, i64) = db
            .query_row(
                "SELECT state,attempts,next FROM outbox WHERE id=?1",
                [job],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        s.push_result(job, ok, permanent, now()).unwrap();
        let after: (String, i64, i64) = db
            .query_row(
                "SELECT state,attempts,next FROM outbox WHERE id=?1",
                [job],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(
            after, before,
            "a stale send result must never overwrite cancelled state or retry metadata"
        );
    }
}

#[test]
fn worker_rechecks_after_provider_jwt_before_network_when_a_fetched_job_is_revoked() {
    let mut f = Fixture::new();
    let s = Store::open(&f.db).unwrap();
    let d = pair(&s, "fixture-jwt-barrier-code", "fixture");
    let id = d["deviceId"].as_str().unwrap();
    s.device_token(id, &"a".repeat(64), "sandbox").unwrap();
    s.create("h", question("q"), now()).unwrap();
    // FIFO is a deterministic barrier in provider_token(): batch was already fetched, JWT not ready.
    let fifo = f.root.join("public-fixture-key.fifo");
    let fifo_c = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
    unsafe extern "C" {
        fn mkfifo(path: *const std::ffi::c_char, mode: u32) -> i32;
    }
    assert_eq!(unsafe { mkfifo(fifo_c.as_ptr(), 0o600) }, 0);
    let proxy = TcpListener::bind("127.0.0.1:0").unwrap();
    proxy.set_nonblocking(true).unwrap();
    let proxy_url = format!("http://{}", proxy.local_addr().unwrap());
    f.start(json!({"teamId":"FIXTURE","keyId":"FIXTURE","topic":"fixture.invalid","privateKeyPath":fifo}),Some(proxy_url));
    #[cfg(target_os = "macos")]
    const NONBLOCK: i32 = 0x4;
    #[cfg(target_os = "linux")]
    const NONBLOCK: i32 = 0x800;
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut writer = loop {
        match fs::OpenOptions::new()
            .write(true)
            .custom_flags(NONBLOCK)
            .open(&fifo)
        {
            Ok(file) => break file,
            Err(_) => {
                assert!(
                    Instant::now() < deadline,
                    "worker did not reach JWT barrier"
                );
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    };
    s.revoke_device(id).unwrap();
    let pem = SigningKey::from_slice(&[7u8; 32])
        .unwrap()
        .to_pkcs8_pem(LineEnding::LF)
        .unwrap();
    writer.write_all(pem.as_bytes()).unwrap();
    drop(writer);
    let deadline = Instant::now() + Duration::from_millis(1400);
    let mut network_started = false;
    while Instant::now() < deadline {
        match proxy.accept() {
            Ok((mut stream, _)) => {
                network_started = true;
                stream
                    .set_read_timeout(Some(Duration::from_millis(200)))
                    .unwrap();
                let mut data = [0u8; 512];
                let _ = stream.read(&mut data);
                let _ = stream.write_all(b"HTTP/1.1 503 Fixture only\r\nContent-Length: 0\r\n\r\n");
                break;
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(10))
            }
            Err(e) => panic!("fixture proxy: {e}"),
        }
    }
    assert!(
        !network_started,
        "worker began network after revocation while JWT was blocked; localhost proxy never forwards to APNs"
    );
}

#[test]
fn widget_operator_retry_is_explicit_versioned_and_preserves_auth_alert_and_claimed_request() {
    use agentinbox::widget_push::{WidgetDelivery, WidgetFailure};
    let f = Fixture::new();
    let s = Store::open(&f.db).unwrap();
    let d = pair(&s, "fixture-widget-retry-code", "fixture");
    let id = d["deviceId"].as_str().unwrap();
    s.device_token(id, &"b".repeat(64), "sandbox").unwrap();
    s.widget_token(id, &"a".repeat(64), "sandbox", true, 1, now() - 10)
        .unwrap();
    s.create("h", question("claimed"), now()).unwrap();
    s.respond(id,json!({"requestId":"claimed","responseId":"original-response","revision":1,"optionIds":["a"],"text":null,"answers":{}}),now()).unwrap();
    s.claim_one("h", "claimed", now()).unwrap();
    let old = s.widget_batch(now() + 3).unwrap().remove(0);
    s.widget_result(
        &old,
        WidgetDelivery::Rejected(WidgetFailure::TopicDisallowed),
        now() + 3,
    )
    .unwrap();
    let db = Connection::open(&f.db).unwrap();
    let before = request_snapshot(&db);
    let auth_before = revocation_snapshot(&db, id);
    let result = f.admin(&["retry-widget", id]);
    assert!(result.status.success(), "explicit Widget retry missing");
    let result: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(result["queued"], true);
    assert_eq!(request_snapshot(&db), before);
    assert_eq!(revocation_snapshot(&db, id), auth_before);
    assert_eq!(s.widget_registration_revision(id).unwrap(), 1);
    let new = s.widget_batch(now() + 10).unwrap().remove(0);
    assert!(new.token_version > old.token_version && new.generation > old.generation);
    s.widget_result(&old, WidgetDelivery::Unregistered, now() + 10)
        .unwrap();
    assert!(s.widget_job_authorized(&new, now() + 10).unwrap());
    s.revoke_device(id).unwrap();
    assert!(!f.admin(&["retry-widget", id]).status.success());
    assert!(
        !f.admin(&["retry-widget", "device-does-not-exist"])
            .status
            .success()
    );
}

#[test]
fn widget_worker_checks_revocation_and_token_rotation_after_jwt_io_before_network() {
    for action in ["allow", "revoke", "rotate"] {
        let mut f = Fixture::new();
        let s = Store::open(&f.db).unwrap();
        let d = pair(&s, "widget-worker-barrier-fixture", "fixture");
        let id = d["deviceId"].as_str().unwrap();
        s.widget_token(id, &"a".repeat(64), "sandbox", true, 1, now() - 10)
            .unwrap();
        let fifo = f.root.join("widget-public-key.fifo");
        let c = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        unsafe extern "C" {
            fn mkfifo(path: *const std::ffi::c_char, mode: u32) -> i32;
        }
        assert_eq!(unsafe { mkfifo(c.as_ptr(), 0o600) }, 0);
        let proxy = TcpListener::bind("127.0.0.1:0").unwrap();
        proxy.set_nonblocking(true).unwrap();
        f.start(json!({"teamId":"FIXTURE","keyId":"FIXTURE","topic":"fixture.invalid","privateKeyPath":fifo}),Some(format!("http://{}",proxy.local_addr().unwrap())));
        #[cfg(target_os = "macos")]
        const NONBLOCK: i32 = 0x4;
        #[cfg(target_os = "linux")]
        const NONBLOCK: i32 = 0x800;
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut writer = loop {
            match fs::OpenOptions::new()
                .write(true)
                .custom_flags(NONBLOCK)
                .open(&fifo)
            {
                Ok(w) => break w,
                Err(_) => {
                    assert!(
                        Instant::now() < deadline,
                        "widget worker did not reach provider JWT barrier"
                    );
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
        };
        match action {
            "revoke" => s.revoke_device(id).unwrap(),
            "rotate" => {
                s.widget_token(id, &"b".repeat(64), "sandbox", true, 2, now())
                    .unwrap();
            }
            _ => {}
        }
        let pem = SigningKey::from_slice(&[7u8; 32])
            .unwrap()
            .to_pkcs8_pem(LineEnding::LF)
            .unwrap();
        writer.write_all(pem.as_bytes()).unwrap();
        drop(writer);
        let deadline = Instant::now() + Duration::from_millis(1300);
        let mut network = false;
        while Instant::now() < deadline {
            match proxy.accept() {
                Ok((mut stream, _)) => {
                    network = true;
                    stream
                        .set_read_timeout(Some(Duration::from_millis(100)))
                        .unwrap();
                    let mut data = [0u8; 512];
                    let _ = stream.read(&mut data);
                    let _ =
                        stream.write_all(b"HTTP/1.1 503 Fixture only\r\nContent-Length: 0\r\n\r\n");
                    break;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10))
                }
                Err(e) => panic!("fixture proxy: {e}"),
            }
        }
        assert_eq!(
            network,
            action == "allow",
            "network must start for authorized control and never for revoked/rotated old snapshot; proxy never forwards to APNs"
        );
    }
}

#[test]
#[ignore = "requires explicit pre-Widget native binary via AGENTINBOX_PREVIOUS_BINARY"]
fn real_pre_widget_operator_revoke_remains_effective_when_new_widget_tables_survive_rollback() {
    use agentinbox::widget_push::WidgetDelivery;
    let previous = std::env::var_os("AGENTINBOX_PREVIOUS_BINARY")
        .expect("explicit previous native binary required");
    let f = Fixture::new();
    let s = Store::open(&f.db).unwrap();
    let d = pair(&s, "public-old-binary-revoke-fixture", "fixture");
    let id = d["deviceId"].as_str().unwrap();
    s.device_token(id, &"b".repeat(64), "sandbox").unwrap();
    s.widget_token(id, &"a".repeat(64), "sandbox", true, 1, now() - 10)
        .unwrap();
    let fetched = s.widget_batch(now()).unwrap().remove(0);
    let db = Connection::open(&f.db).unwrap();
    let old = Command::new(previous)
        .arg("device-admin")
        .arg(&f.db)
        .args(["revoke", id])
        .output()
        .unwrap();
    assert!(
        old.status.success(),
        "pre-Widget operator did not support expected baseline revoke"
    );
    assert_eq!(
        db.query_row(
            "SELECT active FROM widget_tokens WHERE device=?1",
            [id],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1,
        "old operator must leave unknown new Widget tables untouched"
    );
    assert!(s.is_revoked(id).unwrap());
    assert!(!s.widget_job_authorized(&fetched, now()).unwrap());
    s.widget_result(&fetched, WidgetDelivery::Delivered, now())
        .unwrap();
    drop(s);
    let recovered = Store::open(&f.db).unwrap();
    assert!(recovered.widget_batch(now() + 100).unwrap().is_empty());
    assert!(
        recovered
            .device_credential(d["token"].as_str().unwrap())
            .unwrap()
            .is_none()
    );
    assert!(!f.admin(&["retry-widget", id]).status.success());
}
