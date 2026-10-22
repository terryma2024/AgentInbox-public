//! Widget registration uses public disposable fixture identities only.
use reqwest::blocking::Client;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::{
    fs,
    net::TcpListener,
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::Duration,
};
const DEVICE: &str = "widget-public-device-fixture-00001";
const OTHER: &str = "widget-public-other-fixture-00001";
const HOST: &str = "widget-public-host-fixture-00001";
struct Relay {
    root: PathBuf,
    base: String,
    child: Child,
    client: Client,
}
impl Relay {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("widget-http-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let base = format!("http://127.0.0.1:{port}");
        let config = json!({"listen":format!("127.0.0.1:{port}"),"database":root.join("test.sqlite"),"credentials":[{"id":"d","role":"device","token":DEVICE},{"id":"other","role":"device","token":OTHER},{"id":"h","role":"host","hostId":"h","token":HOST}],"apns":null});
        fs::write(root.join("relay.json"), config.to_string()).unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_agentinbox"))
            .args(["relay", "--config"])
            .arg(root.join("relay.json"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let r = Self {
            root,
            base,
            child,
            client: Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(4))
                .build()
                .unwrap(),
        };
        for _ in 0..60 {
            if r.client
                .get(format!("{}/v1/hosts", r.base))
                .bearer_auth(DEVICE)
                .send()
                .is_ok()
            {
                return r;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        panic!("fixture relay not ready")
    }
    fn post(&self, key: &str, path: &str, v: Value) -> (u16, Value) {
        let response = self
            .client
            .post(format!("{}{path}", self.base))
            .bearer_auth(key)
            .json(&v)
            .send()
            .unwrap();
        let status = response.status().as_u16();
        (status, response.json().unwrap())
    }
}
impl Drop for Relay {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.root);
    }
}
#[test]
fn widget_endpoint_binds_authenticated_device_and_rejects_host_and_bad_shapes() {
    let r = Relay::new();
    let body = json!({"token":"a".repeat(64),"environment":"sandbox","registrationRevision":1,"deviceId":"other"});
    assert_eq!(
        r.post(HOST, "/v1/devices/widget-token", body.clone()).0,
        403
    );
    assert_eq!(
        r.post("invalid-fixture", "/v1/devices/widget-token", body.clone())
            .0,
        401
    );
    assert_eq!(
        r.post(DEVICE, "/v1/devices/widget-token", body.clone()),
        (200, json!({"registered":true}))
    );
    let db = Connection::open(r.root.join("test.sqlite")).unwrap();
    assert_eq!(
        db.query_row("SELECT device FROM widget_tokens", [], |row| row
            .get::<_, String>(0))
            .unwrap(),
        "d"
    );
    let generation: i64 = db
        .query_row(
            "SELECT generation FROM widget_updates WHERE device='d'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        r.post(DEVICE, "/v1/devices/widget-token", body.clone()).0,
        200
    );
    assert_eq!(
        db.query_row(
            "SELECT generation FROM widget_updates WHERE device='d'",
            [],
            |row| row.get::<_, i64>(0)
        )
        .unwrap(),
        generation
    );
    for invalid in [
        json!({"token":"secret-not-hex","environment":"sandbox","registrationRevision":1}),
        json!({"token":"a".repeat(64),"environment":"wrong","registrationRevision":1}),
        json!({"token":"a".repeat(64),"environment":"sandbox","registrationRevision":1,"active":"true"}),
        json!({"token":"a".repeat(64),"environment":"sandbox","registrationRevision":1,"active":null}),
    ] {
        let result = r.post(DEVICE, "/v1/devices/widget-token", invalid);
        assert_eq!(result.0, 400);
        assert!(!result.1.to_string().contains("secret-not-hex"));
    }
    assert_eq!(r.post(OTHER, "/v1/devices/widget-token", body).0, 200);
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM widget_tokens", [], |row| row
            .get::<_, i64>(0))
            .unwrap(),
        2
    );
    assert_eq!(r.post(DEVICE, "/v1/devices/revoke", json!({})).0, 200);
    assert_eq!(
        r.post(
            DEVICE,
            "/v1/devices/widget-token",
            json!({"token":"b".repeat(64),"environment":"sandbox","registrationRevision":1})
        )
        .0,
        401
    );
}
#[test]
fn widget_registration_revision_is_required_and_prevents_late_old_http_overwrite() {
    let r = Relay::new();
    let path = "/v1/devices/widget-token";
    assert_eq!(
        r.post(
            DEVICE,
            path,
            json!({"token":"a".repeat(64),"environment":"sandbox"})
        )
        .0,
        400
    );
    let a = json!({"token":"a".repeat(64),"environment":"sandbox","registrationRevision":1});
    let b = json!({"token":"b".repeat(64),"environment":"sandbox","registrationRevision":2});
    assert_eq!(r.post(DEVICE, path, b.clone()).0, 200);
    assert_eq!(r.post(DEVICE, path, a).0, 409);
    assert_eq!(r.post(DEVICE, path, b.clone()).0, 200);
    let mut conflict = b;
    conflict["active"] = json!(false);
    assert_eq!(r.post(DEVICE, path, conflict).0, 409);
    for invalid in [
        json!(0),
        json!(-1),
        json!("3"),
        json!(1.5),
        Value::Null,
        json!(18446744073709551615u64),
    ] {
        assert_eq!(r.post(DEVICE,path,json!({"token":"a".repeat(64),"environment":"sandbox","registrationRevision":invalid})).0,400);
    }
    let get = |key: &str| {
        let result = r
            .client
            .get(format!("{}{}?deviceId=other", r.base, path))
            .bearer_auth(key)
            .send()
            .unwrap();
        let status = result.status().as_u16();
        (status, result.json::<Value>().unwrap())
    };
    assert_eq!(get(DEVICE), (200, json!({"registrationRevision":2})));
    assert_eq!(get(OTHER), (200, json!({"registrationRevision":0})));
    assert_eq!(get(HOST).0, 403);
}
