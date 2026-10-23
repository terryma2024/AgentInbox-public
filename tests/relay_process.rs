//! Black-box HTTP/process recovery tests. Uses only isolated temp databases and fixture credentials.
use reqwest::blocking::Client;
use serde_json::{Value, json};
use std::{
    fs,
    net::TcpListener,
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::Duration,
};
const DEVICE: &str = "isolated-device-fixture-0000000001";
const HOST_A: &str = "isolated-host-a-fixture-0000000001";
const HOST_B: &str = "isolated-host-b-fixture-0000000001";
struct Relay {
    dir: PathBuf,
    base: String,
    child: Option<Child>,
    config: Value,
    client: Client,
}
impl Relay {
    fn new() -> Self {
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let dir = std::env::temp_dir().join(format!("agentinbox-http-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        let config = json!({"listen":format!("127.0.0.1:{port}"),"database":dir.join("test.sqlite").to_str().unwrap(),"credentials":[
            {"id":"device","role":"device","token":DEVICE},
            {"id":"host-a","role":"host","hostId":"a","token":HOST_A},
            {"id":"host-b","role":"host","hostId":"b","token":HOST_B}],"apns":null});
        let mut r = Self {
            dir,
            base: format!("http://127.0.0.1:{port}"),
            child: None,
            config,
            client: Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(4))
                .build()
                .unwrap(),
        };
        r.write_config();
        r.start();
        r
    }
    fn write_config(&self) {
        fs::write(self.dir.join("relay.json"), self.config.to_string()).unwrap();
    }
    fn start(&mut self) {
        self.child = Some(
            Command::new(env!("CARGO_BIN_EXE_agentinbox"))
                .args(["relay", "--config"])
                .arg(self.dir.join("relay.json"))
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .unwrap(),
        );
        for _ in 0..50 {
            if let Ok(response) = self
                .client
                .get(format!("{}/v1/requests", self.base))
                .bearer_auth(DEVICE)
                .send()
            {
                if response.status().is_success() {
                    return;
                }
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("isolated relay startup failed");
    }
    fn stop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
    fn call(&self, token: &str, path: &str, body: Option<Value>) -> (u16, Value) {
        let request = match body {
            Some(v) => self.client.post(format!("{}{}", self.base, path)).json(&v),
            None => self.client.get(format!("{}{}", self.base, path)),
        };
        let response = request.bearer_auth(token).send().unwrap();
        let status = response.status().as_u16();
        let value = response.json().unwrap();
        (status, value)
    }
    fn create(&self, id: &str, host: &str, token: &str) -> Value {
        let now = agentinbox::model::now();
        let v = json!({"requestId":id,"hostId":host,"engine":"codex","runtimeId":"isolated-runtime","sessionId":format!("session-{id}"),"turnId":"turn-1","itemId":"item-1","nativeRequestId":"rpc-1","revision":1,"expiresAt":now+300,"kind":"choice","title":"隔离测试","body":"请选择","options":[{"id":"one","label":"一"},{"id":"two","label":"二"}],"multiSelect":false,"native":{"privateBinding":"do-not-expose"}});
        assert_eq!(self.call(token, "/v1/host/requests", Some(v)).0, 200);
        self.call(DEVICE, &format!("/v1/requests/{id}"), None).1
    }
}
impl Drop for Relay {
    fn drop(&mut self) {
        self.stop();
        let _ = fs::remove_dir_all(&self.dir);
    }
}
fn answer(id: &str, rid: &str) -> Value {
    json!({"requestId":id,"responseId":rid,"revision":1,"optionIds":["one"],"text":null,"answers":{}})
}
#[test]
fn role_boundaries_filter_hosts_and_revoke_immediately() {
    let mut r = Relay::new();
    let q = r.create("q-a", "a", HOST_A);
    r.create("q-b", "b", HOST_B);
    assert!(q.get("native").is_none());
    assert_eq!(r.call(DEVICE, "/v1/host/requests", Some(json!({}))).0, 403);
    assert_eq!(r.call(HOST_B, "/v1/requests/q-a", None).0, 403);
    assert_eq!(
        r.call(HOST_A, "/v1/requests", None).1["requests"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        r.call("invalid-fixture-credential", "/v1/requests", None).0,
        401
    );
    r.config["credentials"][0]["revoked"] = json!(true);
    r.write_config();
    assert_eq!(r.call(DEVICE, "/v1/requests", None).0, 401);
    assert_eq!(
        r.call(
            DEVICE,
            "/v1/requests/q-a/responses",
            Some(answer("q-a", "r-a"))
        )
        .0,
        401
    );
}
#[test]
fn claimed_lost_receipt_survives_restart_as_unknown_without_redispatch() {
    let mut r = Relay::new();
    r.create("q", "a", HOST_A);
    let a = answer("q", "response-1");
    assert_eq!(
        r.call(DEVICE, "/v1/requests/q/responses", Some(a.clone()))
            .0,
        200
    );
    let path = "/v1/host/responses?hostId=a&requestId=q";
    assert_eq!(
        r.call(HOST_A, path, None).1["responses"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    r.stop();
    r.start();
    assert_eq!(r.call(DEVICE, "/v1/requests/q", None).1["state"], "unknown");
    assert_eq!(
        r.call(HOST_A, path, None).1["responses"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        r.call(DEVICE, "/v1/requests/q/responses", Some(a)).1["state"],
        "unknown"
    );
    let receipt = json!({"requestId":"q","responseId":"response-1","state":"adopted","evidence":{"nativeReceipt":"exact-original-test-only"}});
    assert_eq!(
        r.call(HOST_B, "/v1/host/receipt", Some(receipt.clone())).0,
        403
    );
    assert_eq!(r.call(HOST_A, "/v1/host/receipt", Some(receipt)).0, 200);
    assert_eq!(r.call(DEVICE, "/v1/requests/q", None).1["state"], "adopted");
}
#[test]
fn http_concurrent_candidates_dispatch_once_and_never_claim_other_session() {
    let r = Relay::new();
    r.create("q-a", "a", HOST_A);
    r.create("q-b", "a", HOST_A);
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(9));
    let joins: Vec<_> = (0..8)
        .map(|i| {
            let client = r.client.clone();
            let url = format!("{}/v1/requests/q-a/responses", r.base);
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                client
                    .post(url)
                    .bearer_auth(DEVICE)
                    .json(&answer("q-a", &format!("race-{i}")))
                    .send()
                    .unwrap()
                    .status()
                    .is_success()
            })
        })
        .collect();
    barrier.wait();
    assert_eq!(
        joins
            .into_iter()
            .map(|j| j.join().unwrap())
            .filter(|x| *x)
            .count(),
        1
    );
    assert_eq!(
        r.call(
            DEVICE,
            "/v1/requests/q-b/responses",
            Some(answer("q-b", "second"))
        )
        .0,
        200
    );
    let claim = r
        .call(HOST_A, "/v1/host/responses?hostId=a&requestId=q-a", None)
        .1;
    assert_eq!(claim["responses"].as_array().unwrap().len(), 1);
    assert_eq!(claim["responses"][0]["requestId"], "q-a");
    assert_eq!(
        r.call(HOST_A, "/v1/host/responses?hostId=a&requestId=q-a", None)
            .1["responses"],
        json!([])
    );
    assert_eq!(
        r.call(HOST_A, "/v1/host/responses?hostId=a&requestId=q-b", None)
            .1["responses"][0]["requestId"],
        "q-b"
    );
}
#[test]
fn native_private_client_does_not_send_local_auth_through_environment_proxy() {
    let r = Relay::new();
    r.create("private-client", "a", HOST_A);
    // Public, fixed fixture token only; never an Agent or device production credential.
    let key = r.dir.join("public-fixture-token");
    fs::write(&key, DEVICE).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_agentinbox"))
        .args(["client", &r.base])
        .arg(&key)
        .args(["GET", "/v1/requests/private-client"])
        .env("HTTP_PROXY", "http://127.0.0.1:9")
        .env("http_proxy", "http://127.0.0.1:9")
        .env("ALL_PROXY", "http://127.0.0.1:9")
        .env("NO_PROXY", "")
        .env("no_proxy", "")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "private relay API must bypass environment proxies"
    );
    let v: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(v["requestId"], "private-client");
}
#[test]
fn idle_host_heartbeat_is_authenticated_and_host_bound() {
    let r = Relay::new();
    assert_eq!(r.call(DEVICE, "/v1/host/heartbeat", Some(json!({}))).0, 403);
    assert_eq!(
        r.call(HOST_A, "/v1/host/heartbeat", Some(json!({"hostId":"b"})))
            .0,
        403
    );
    assert_eq!(r.call(HOST_A, "/v1/host/heartbeat", Some(json!({}))).0, 200);
    let hosts = r.call(DEVICE, "/v1/hosts", None).1;
    assert_eq!(hosts["hosts"].as_array().unwrap().len(), 1);
    assert_eq!(hosts["hosts"][0]["hostId"], "a");
    assert_eq!(hosts["hosts"][0]["online"], true);
}
#[test]
fn startup_snapshot_cannot_be_hidden_by_other_hosts_or_ui_history_limit() {
    let r = Relay::new();
    r.create("old-own", "a", HOST_A);
    assert_eq!(
        r.call(
            DEVICE,
            "/v1/requests/old-own/responses",
            Some(answer("old-own", "old-response"))
        )
        .0,
        200
    );
    for i in 0..205 {
        r.create(&format!("other-{i}"), "b", HOST_B);
    }
    assert_eq!(r.call(DEVICE, "/v1/host/requests", None).0, 403);
    let (status, snapshot) = r.call(HOST_A, "/v1/host/requests", None);
    assert_eq!(status, 200);
    assert_eq!(snapshot["requests"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["requests"][0]["requestId"], "old-own");
    assert_eq!(snapshot["requests"][0]["responseId"], "old-response");
}

#[test]
fn keep_alive_burst_connections_do_not_starve_later_authenticated_requests() {
    let r = Relay::new();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(25));
    let joins: Vec<_> = (0..24)
        .map(|_| {
            let barrier = barrier.clone();
            let base = r.base.clone();
            std::thread::spawn(move || {
                let client = Client::builder()
                    .no_proxy()
                    .timeout(Duration::from_secs(4))
                    .build()
                    .unwrap();
                barrier.wait();
                let response = client
                    .get(format!("{base}/v1/requests"))
                    .bearer_auth(DEVICE)
                    .send()
                    .unwrap();
                assert_eq!(response.status().as_u16(), 200);
                let body: Value = response.json().unwrap();
                assert_eq!(body["requests"], json!([]));
                // Retain idle keep-alive sockets while other burst connections run.
                client
            })
        })
        .collect();
    barrier.wait();
    let keepers: Vec<_> = joins.into_iter().map(|j| j.join().unwrap()).collect();
    assert_eq!(keepers.len(), 24);
    assert_eq!(r.call(DEVICE, "/v1/requests", None).0, 200);
}

#[test]
fn upgrade_status_is_host_bound_and_includes_unknown_without_question_contents() {
    let r = Relay::new();
    r.create("upgrade-pending", "a", HOST_A);
    r.create("upgrade-submitting", "a", HOST_A);
    r.create("upgrade-unknown", "a", HOST_A);
    r.create("foreign-upgrade-pending", "b", HOST_B);
    for id in ["upgrade-submitting", "upgrade-unknown"] {
        assert_eq!(
            r.call(
                DEVICE,
                &format!("/v1/requests/{id}/responses"),
                Some(answer(id, &format!("response-{id}")))
            )
            .0,
            200
        );
    }
    assert_eq!(
        r.call(HOST_A, "/v1/host/responses?requestId=upgrade-unknown", None)
            .1["responses"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(r.call(HOST_A,"/v1/host/receipt",Some(json!({"requestId":"upgrade-unknown","responseId":"response-upgrade-unknown","state":"unknown","evidence":{"test":"receipt absent"}}))).0,200);
    let (status, value) = r.call(HOST_A, "/v1/host/upgrade-status?hostId=b", None);
    assert_eq!(status, 200);
    assert_eq!(
        value,
        json!({"hostId":"a","pending":1,"submitting":1,"unknown":1,"unknownRequests":1,"awaitingContinuation":0})
    );
    assert_eq!(
        r.call(HOST_B, "/v1/host/upgrade-status", None).1,
        json!({"hostId":"b","pending":1,"submitting":0,"unknown":0,"unknownRequests":0,"awaitingContinuation":0})
    );
    assert_eq!(r.call(DEVICE, "/v1/host/upgrade-status", None).0, 403);
    assert_eq!(
        r.call("invalid-fixture-token", "/v1/host/upgrade-status", None)
            .0,
        401
    );
    assert_eq!(r.call(HOST_A,"/v1/host/receipt",Some(json!({"requestId":"upgrade-unknown","responseId":"response-upgrade-unknown","state":"adopted","evidence":{"test":"exact original result recovered"}}))).0,200);
    assert_eq!(
        r.call(HOST_A, "/v1/host/upgrade-status", None).1["unknown"],
        0
    );
}

#[test]
fn diagnostics_http_enforces_roles_device_ownership_and_separate_push_probe() {
    let r = Relay::new();
    let now = agentinbox::model::now();
    r.call(HOST_A,"/v1/host/heartbeat",Some(json!({"diagnostics":{"codex":"disabled","claude":"unobserved","reconciled":true,"draining":false}})));
    assert_eq!(
        r.call(DEVICE, "/v1/diagnostics", None).1["hosts"][0]["observation"]["codex"],
        "disabled"
    );
    assert_ne!(r.call(HOST_A, "/v1/diagnostics", None).0, 200);
    assert_eq!(r.call(DEVICE, "/v1/host/diagnostics/next", None).0, 403);
    assert_eq!(
        r.call(
            DEVICE,
            "/v1/diagnostics/tests",
            Some(json!({"testId":"fixture-http-push","hostId":"a","mode":"push"}))
        )
        .0,
        200
    );
    assert!(
        r.call(DEVICE, "/v1/requests", None).1["requests"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let status = r
        .call(DEVICE, "/v1/diagnostics/tests/fixture-http-push", None)
        .1;
    assert_eq!(status["received"], false);
    assert_eq!(status["expiresAt"].as_i64().unwrap() >= now + 180, true);
    let q = status["request"]["requestId"].as_str().unwrap();
    r.call(
        DEVICE,
        "/v1/diagnostics/tests",
        Some(json!({"testId":"fixture-http-reply","hostId":"a"})),
    );
    assert_eq!(
        r.call(HOST_A, "/v1/host/diagnostics/next", None).1["test"]["testId"],
        "fixture-http-reply"
    );
    assert!(r.call(HOST_A, "/v1/host/diagnostics/next", None).1["test"].is_null());
    assert_eq!(r.call(HOST_B,"/v1/host/diagnostics/result",Some(json!({"testId":"fixture-http-reply","phase":"unsupported","code":"nativeUnavailable"}))).0,409);
    assert_eq!(r.call(HOST_A,"/v1/host/diagnostics/result",Some(json!({"testId":"fixture-http-reply","phase":"unsupported","code":"nativeUnavailable"}))).0,200);
    assert_eq!(r.call(DEVICE, &format!("/v1/requests/{q}"), None).0, 200);
    assert_eq!(
        r.call("invalid-diagnostic-fixture", "/v1/diagnostics", None)
            .0,
        401
    );
}
