//! Process-level recovery with a deliberately simulated hook engine. No Agent CLI, phone,
//! pairing, deployment, or production credentials are used.
use reqwest::blocking::Client;
use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    net::TcpListener,
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
const HOST: &str = "recovery-round2-public-host-fixture";
const DEVICE: &str = "recovery-round2-public-device-fixture";

struct OwnedProcess(Option<Child>);
impl OwnedProcess {
    fn spawn(command: &mut Command) -> Self {
        Self(Some(command.spawn().unwrap()))
    }
    fn stop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
impl Drop for OwnedProcess {
    fn drop(&mut self) {
        self.stop();
    }
}
struct Fixture {
    root: PathBuf,
    base: String,
    socket: PathBuf,
    host_config: PathBuf,
    host: OwnedProcess,
    relay: OwnedProcess,
    peers: Vec<OwnedProcess>,
    client: Client,
    fault_stop: Arc<AtomicBool>,
    lost_claims: Arc<AtomicUsize>,
    block_receipts: Arc<AtomicBool>,
    fault_thread: Option<thread::JoinHandle<()>>,
}
impl Fixture {
    fn new(lose_first_claim: bool, block_adoption_receipts: bool) -> Self {
        let root = PathBuf::from("/tmp").join(format!(
            "ainb-r2-{}",
            &uuid::Uuid::new_v4().to_string()[..8]
        ));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let host_id = format!("recovery-fixture-{}", uuid::Uuid::new_v4());
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let base = format!("http://127.0.0.1:{port}");
        let relay_config = root.join("relay.json");
        fs::write(&relay_config,json!({"listen":format!("127.0.0.1:{port}"),"database":root.join("relay.sqlite"),"credentials":[{"id":"fixture-host","role":"host","hostId":host_id,"token":HOST},{"id":"fixture-device","role":"device","token":DEVICE}],"apns":null}).to_string()).unwrap();
        let relay = OwnedProcess::spawn(
            Command::new(env!("CARGO_BIN_EXE_agentinbox"))
                .args(["relay", "--config"])
                .arg(&relay_config)
                .stdout(Stdio::null())
                .stderr(Stdio::inherit()),
        );
        let client = Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(4))
            .build()
            .unwrap();
        until("isolated relay ready", || {
            client
                .get(format!("{base}/v1/requests"))
                .bearer_auth(DEVICE)
                .send()
                .ok()
                .is_some_and(|r| r.status().is_success())
        });
        let fault_stop = Arc::new(AtomicBool::new(false));
        let lost_claims = Arc::new(AtomicUsize::new(0));
        let block_receipts = Arc::new(AtomicBool::new(block_adoption_receipts));
        let mut fault_thread = None;
        let host_base = if lose_first_claim || block_adoption_receipts {
            let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
            let url = format!("http://{}", server.server_addr().to_ip().unwrap());
            let stopped = fault_stop.clone();
            let losses = lost_claims.clone();
            let receipts_offline = block_receipts.clone();
            let upstream = base.clone();
            let forward = client.clone();
            fault_thread = Some(thread::spawn(move || {
                while !stopped.load(Ordering::SeqCst) {
                    let Some(mut q) = server.recv_timeout(Duration::from_millis(50)).unwrap()
                    else {
                        continue;
                    };
                    let path = q.url().to_string();
                    let method = q.method().as_str().to_string();
                    let mut request = forward
                        .request(method.parse().unwrap(), format!("{upstream}{path}"))
                        .bearer_auth(HOST);
                    if method == "POST" {
                        let body: Value = serde_json::from_reader(q.as_reader()).unwrap();
                        if path == "/v1/host/receipt"
                            && body["state"] == "adopted"
                            && receipts_offline.load(Ordering::SeqCst)
                        {
                            losses.fetch_add(1, Ordering::SeqCst);
                            q.respond(tiny_http::Response::from_string(json!({"error":"public fixture: adoption receipt offline before commit"}).to_string()).with_status_code(503)).unwrap();
                            continue;
                        }
                        request = request.json(&body);
                    }
                    let response = request.send().unwrap();
                    let status = response.status().as_u16();
                    let body: Value = response.json().unwrap();
                    if lose_first_claim
                        && path.starts_with("/v1/host/responses?")
                        && body["responses"].as_array().is_some_and(|r| !r.is_empty())
                        && losses.load(Ordering::SeqCst) == 0
                    {
                        losses.fetch_add(1, Ordering::SeqCst);
                        q.respond(tiny_http::Response::from_string(json!({"error":"public fixture: claim committed, response withheld"}).to_string()).with_status_code(503)).unwrap();
                    } else {
                        let _ = q.respond(
                            tiny_http::Response::from_string(body.to_string())
                                .with_status_code(status),
                        );
                    }
                }
            }));
            url
        } else {
            base.clone()
        };
        let token = root.join("public-fixture-token");
        fs::write(&token, HOST).unwrap();
        fs::set_permissions(&token, fs::Permissions::from_mode(0o600)).unwrap();
        let state = root.join("state");
        let socket = state.join("ipc/hook.sock");
        let host_config = root.join("host.json");
        fs::write(&host_config,json!({"hostId":host_id,"relayUrl":host_base,"tokenFile":token,"stateDir":state,"ipcSocket":socket,"scopes":[root],"requestTtl":60}).to_string()).unwrap();
        let host = Self::spawn_host(&host_config);
        let this = Self {
            root,
            base,
            socket,
            host_config,
            host,
            relay,
            peers: vec![],
            client,
            fault_stop,
            lost_claims,
            block_receipts,
            fault_thread,
        };
        until("host startup reconciliation", || {
            this.control("status")
                .is_some_and(|s| s["startupReconciled"] == true)
        });
        this
    }
    fn spawn_host(path: &Path) -> OwnedProcess {
        OwnedProcess::spawn(
            Command::new(env!("CARGO_BIN_EXE_agentinbox"))
                .arg("host")
                .arg(path)
                .stdout(Stdio::null())
                .stderr(Stdio::inherit()),
        )
    }
    fn control(&self, operation: &str) -> Option<Value> {
        let mut stream = UnixStream::connect(&self.socket).ok()?;
        stream.set_read_timeout(Some(Duration::from_secs(3))).ok()?;
        writeln!(stream, "{}", json!({"operation":operation})).ok()?;
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).ok()?;
        serde_json::from_str(&line).ok()
    }
    fn hostctl(&self, operation: &str) -> Value {
        let output = Command::new(env!("CARGO_BIN_EXE_agentinbox"))
            .arg("hostctl")
            .arg(&self.socket)
            .arg(operation)
            .output()
            .unwrap();
        assert!(output.status.success());
        serde_json::from_slice(&output.stdout).unwrap()
    }
    fn call(&self, path: &str, body: Option<Value>) -> (u16, Value) {
        let request = if let Some(body) = body {
            self.client.post(format!("{}{path}", self.base)).json(&body)
        } else {
            self.client.get(format!("{}{path}", self.base))
        };
        let response = request.bearer_auth(DEVICE).send().unwrap();
        (response.status().as_u16(), response.json().unwrap())
    }
    fn peer(&mut self, name: &str) -> PathBuf {
        let output = self.root.join(format!("{name}-deliveries.jsonl"));
        let transcript = self.root.join(format!("{name}-transcript.jsonl"));
        let event = json!({"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":"simulated-recovery-session","prompt_id":format!("prompt-{name}"),"tool_use_id":format!("tool-{name}"),"cwd":self.root,"transcript_path":transcript,"tool_input":{"questions":[{"question":format!("模拟恢复题 {name}"),"header":"模拟","multiSelect":false,"options":[{"label":"Fixture Alpha"},{"label":"Fixture Beta"}]}]}});
        self.peers.push(OwnedProcess::spawn(
            Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "fixture_engine_process", "--nocapture"])
                .env("AINB_RECOVERY_FIXTURE_SOCKET", &self.socket)
                .env("AINB_RECOVERY_FIXTURE_EVENT", event.to_string())
                .env("AINB_RECOVERY_FIXTURE_OUTPUT", &output)
                .stdout(Stdio::null())
                .stderr(Stdio::inherit()),
        ));
        output
    }
    fn request(&self, name: &str) -> Value {
        let mut found = Value::Null;
        until("published exact native binding", || {
            found = self.call("/v1/requests", None).1["requests"]
                .as_array()
                .unwrap()
                .iter()
                .find(|q| q["nativeRequestId"] == format!("tool-{name}"))
                .cloned()
                .unwrap_or(Value::Null);
            !found.is_null()
        });
        found
    }
    fn state(&self, q: &Value) -> Value {
        self.call(
            &format!("/v1/requests/{}", q["requestId"].as_str().unwrap()),
            None,
        )
        .1["state"]
            .clone()
    }
    fn answer(&self, q: &Value, id: &str) -> (u16, Value) {
        self.call(&format!("/v1/requests/{}/responses",q["requestId"].as_str().unwrap()),Some(json!({"requestId":q["requestId"],"responseId":id,"revision":q["revision"],"optionIds":["q0-o1"],"text":null,"answers":{}})))
    }
    fn restart_relay(&mut self) {
        self.relay.stop();
        self.relay = OwnedProcess::spawn(
            Command::new(env!("CARGO_BIN_EXE_agentinbox"))
                .args(["relay", "--config"])
                .arg(self.root.join("relay.json"))
                .stdout(Stdio::null())
                .stderr(Stdio::inherit()),
        );
        until("restarted isolated relay ready", || {
            self.client
                .get(format!("{}/v1/requests", self.base))
                .bearer_auth(DEVICE)
                .send()
                .ok()
                .is_some_and(|r| r.status().is_success())
        });
    }
    fn assert_claimed(&self, request: &Value, response_id: &str) {
        let db = rusqlite::Connection::open_with_flags(
            self.root.join("relay.sqlite"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .unwrap();
        let saved: (String, i64) = db
            .query_row(
                "SELECT id,claimed FROM responses WHERE request=?1",
                [request["requestId"].as_str().unwrap()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            saved,
            (response_id.to_string(), 1),
            "the exact candidate claim must have committed"
        );
    }
    fn restart_host(&mut self) {
        self.host.stop();
        self.host = Self::spawn_host(&self.host_config);
        until("restarted host reconciled", || {
            self.control("status")
                .is_some_and(|s| s["startupReconciled"] == true)
        });
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.host.stop();
        for peer in &mut self.peers {
            peer.stop();
        }
        self.fault_stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.fault_thread.take() {
            let _ = worker.join();
        }
        self.relay.stop();
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn until(label: &str, mut check: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if check() {
            return;
        }
        thread::sleep(Duration::from_millis(20));
    }
    panic!("5 second deadline: {label}");
}
fn deliveries(path: &Path) -> Vec<Value> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|s| serde_json::from_str(s).unwrap())
        .collect()
}
fn binding(request: &Value) -> Value {
    json!({"requestId":request["requestId"],"revision":request["revision"],"hostId":request["hostId"],"runtimeId":request["runtimeId"],"sessionId":request["sessionId"],"turnId":request["turnId"],"nativeRequestId":request["nativeRequestId"],"itemId":request["itemId"]})
}
fn assert_one_bound_delivery(output: &Path, name: &str) {
    let rows = deliveries(output);
    assert_eq!(rows.len(), 1, "only one original IPC callback delivery");
    let input = &rows[0]["output"]["hookSpecificOutput"]["updatedInput"];
    assert_eq!(
        input["questions"][0]["question"],
        format!("模拟恢复题 {name}")
    );
    assert_eq!(
        input["answers"][format!("模拟恢复题 {name}")],
        "Fixture Beta"
    );
}

#[test]
fn fixture_engine_process() {
    let Ok(socket) = std::env::var("AINB_RECOVERY_FIXTURE_SOCKET") else {
        return;
    };
    let event: Value =
        serde_json::from_str(&std::env::var("AINB_RECOVERY_FIXTURE_EVENT").unwrap()).unwrap();
    let mut stream = UnixStream::connect(socket).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(12)))
        .unwrap();
    writeln!(stream,"{}",json!({"hookEvent":event,"engineRuntime":format!("SIMULATED-ENGINE-PROCESS:{}",std::process::id()),"deadline":agentinbox::host::now()+60})).unwrap();
    let mut line = String::new();
    if BufReader::new(stream).read_line(&mut line).unwrap() == 0 {
        return;
    }
    fs::write(
        std::env::var("AINB_RECOVERY_FIXTURE_OUTPUT").unwrap(),
        &line,
    )
    .unwrap();
    let reply: Value = serde_json::from_str(&line).unwrap();
    if reply["output"].is_null() {
        return;
    }
    let input = &reply["output"]["hookSpecificOutput"]["updatedInput"];
    fs::write(event["transcript_path"].as_str().unwrap(),json!({"sessionId":event["session_id"],"promptId":event["prompt_id"],"toolUseResult":{"questions":input["questions"],"answers":input["answers"]},"message":{"content":[{"type":"tool_result","tool_use_id":event["tool_use_id"],"is_error":false}]}}).to_string()).unwrap();
}
#[test]
fn active_hook_defers_upgrade_while_drain_rejects_new_hooks_and_finishes_original() {
    let mut f = Fixture::new(false, false);
    let output = f.peer("active");
    let q = f.request("active");
    let drain = f.hostctl("drain");
    assert_eq!(drain["draining"], true);
    assert_eq!(drain["activeHooks"], 1);
    assert_eq!(drain["activeRequests"], 1);
    let rejected = f.peer("after-drain");
    until("new callback rejected during drain", || {
        !deliveries(&rejected).is_empty()
    });
    assert!(
        deliveries(&rejected)[0]["error"]
            .as_str()
            .unwrap()
            .contains("draining")
    );
    assert_eq!(
        f.call("/v1/requests", None).1["requests"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(f.answer(&q, "drain-answer").0, 200);
    until("original simulated result adopted while draining", || {
        f.state(&q) == "adopted"
    });
    assert_one_bound_delivery(&output, "active");
    until("drain has no callbacks left", || {
        f.control("status").is_some_and(|s| {
            s["activeHooks"] == 0 && s["activeRequests"] == 0 && s["submitting"] == 0
        })
    });
    println!(
        "{}",
        json!({"scope":"simulated engine; real host/relay/hostctl processes","scenario":"active-hook-drain","binding":binding(&q),"upgradeDeferredWhileActive":true,"originalState":"adopted","dispatchCount":1,"newHooksRejected":true})
    );
}
#[test]
fn restarting_host_invalidates_old_callback_and_never_maps_its_answer_to_new_item() {
    let mut f = Fixture::new(false, false);
    let old_output = f.peer("old");
    let old = f.request("old");
    f.restart_host();
    assert_eq!(f.state(&old), "invalidated");
    assert_eq!(f.answer(&old, "old-after-restart").0, 409);
    assert!(deliveries(&old_output).is_empty());
    let new_output = f.peer("new");
    let new = f.request("new");
    assert_ne!(old["requestId"], new["requestId"]);
    assert_ne!(old["nativeRequestId"], new["nativeRequestId"]);
    assert_eq!(f.answer(&new, "new-answer").0, 200);
    until("new exact callback adopted", || f.state(&new) == "adopted");
    assert_one_bound_delivery(&new_output, "new");
    assert!(deliveries(&old_output).is_empty());
    println!(
        "{}",
        json!({"scope":"simulated engine; real host/relay restart","scenario":"host-restart-old-callback","oldBinding":binding(&old),"newBinding":binding(&new),"oldState":"invalidated","oldAnswerHTTP":409,"oldDispatchCount":0,"newDispatchCount":1})
    );
}
#[test]
fn committed_claim_with_lost_http_response_recovers_unknown_without_native_redispatch() {
    let mut f = Fixture::new(true, false);
    let old_output = f.peer("claim-lost");
    let old = f.request("claim-lost");
    assert_eq!(f.answer(&old, "claim-lost-answer").0, 200);
    until("relay claim committed but its response withheld", || {
        f.lost_claims.load(Ordering::SeqCst) == 1
    });
    f.assert_claimed(&old, "claim-lost-answer");
    assert!(deliveries(&old_output).is_empty());
    f.restart_host();
    assert_eq!(f.state(&old), "unknown");
    assert_eq!(f.answer(&old, "another-old-candidate").0, 409);
    let claim = f
        .client
        .get(format!(
            "{}/v1/host/responses?requestId={}",
            f.base,
            old["requestId"].as_str().unwrap()
        ))
        .bearer_auth(HOST)
        .send()
        .unwrap()
        .json::<Value>()
        .unwrap();
    assert_eq!(claim["responses"], json!([]));
    let new_output = f.peer("after-loss");
    let new = f.request("after-loss");
    assert_eq!(f.answer(&new, "fresh-after-loss").0, 200);
    until("fresh request after lost claim adopted", || {
        f.state(&new) == "adopted"
    });
    assert_one_bound_delivery(&new_output, "after-loss");
    assert!(deliveries(&old_output).is_empty());
    assert_eq!(f.lost_claims.load(Ordering::SeqCst), 1);
    println!(
        "{}",
        json!({"scope":"simulated engine; real relay claim with injected lost host HTTP reply","scenario":"claim-response-lost","oldBinding":binding(&old),"newBinding":binding(&new),"oldState":"unknown","oldDispatchCount":0,"reclaimCount":0,"newDispatchCount":1})
    );
}

#[test]
fn native_delivery_then_receipt_outage_survives_both_process_restarts_without_replay() {
    let mut f = Fixture::new(false, true);
    let output = f.peer("receipt-lost");
    let q = f.request("receipt-lost");
    assert_eq!(f.answer(&q, "receipt-lost-answer").0, 200);
    until(
        "simulated engine adopted but relay receipt is blocked",
        || f.lost_claims.load(Ordering::SeqCst) > 0,
    );
    assert_one_bound_delivery(&output, "receipt-lost");
    f.assert_claimed(&q, "receipt-lost-answer");
    assert_eq!(f.state(&q), "submitting");
    let outbox = f
        .root
        .join("state/receipt-outbox")
        .join(format!("{}-adopted.json", q["requestId"].as_str().unwrap()));
    assert!(
        outbox.exists(),
        "exact adoption evidence must be durable before retry/restart"
    );
    f.host.stop();
    f.restart_relay();
    assert_eq!(f.state(&q), "unknown");
    assert_one_bound_delivery(&output, "receipt-lost");
    f.block_receipts.store(false, Ordering::SeqCst);
    f.restart_host();
    until(
        "saved original native adoption receipt reconciles unknown",
        || f.state(&q) == "adopted" && !outbox.exists(),
    );
    assert_eq!(f.answer(&q, "late-competing-answer").0, 409);
    assert_one_bound_delivery(&output, "receipt-lost");
    let response = f
        .client
        .get(format!(
            "{}/v1/host/responses?requestId={}",
            f.base,
            q["requestId"].as_str().unwrap()
        ))
        .bearer_auth(HOST)
        .send()
        .unwrap()
        .json::<Value>()
        .unwrap();
    assert_eq!(response["responses"], json!([]));
    println!(
        "{}",
        json!({"scope":"simulated engine; real host and relay; receipt submission fault before relay commit","scenario":"adoption-receipt-outage","binding":binding(&q),"stateBeforeRestart":"submitting","stateAfterRelayRestart":"unknown","stateAfterReceiptRecovery":"adopted","dispatchCountBeforeAndAfter":1,"reclaimCount":0,"durableOutboxDrained":true})
    );
}

#[test]
fn same_answer_native_result_does_not_attribute_a_remote_winner() {
    let mut f = Fixture::new(false, false);
    let output = f.peer("source-unknown");
    let q = f.request("source-unknown");
    assert_eq!(f.answer(&q, "source-unknown-answer").0, 200);
    until("structured result observed", || f.state(&q) == "adopted");
    let latest = f
        .call(
            &format!("/v1/requests/{}", q["requestId"].as_str().unwrap()),
            None,
        )
        .1;
    assert_eq!(
        latest["replyProgress"]["nativeObservation"],
        "answerSourceUnconfirmed"
    );
    assert!(latest["replyProgress"]["received"].is_null());
    assert!(latest["replyProgress"]["continued"].is_null());
    assert_one_bound_delivery(&output, "source-unknown");
}

#[test]
fn trusted_received_fact_survives_both_restarts_without_inheriting_callback() {
    let mut f = Fixture::new(false, false);
    let output = f.peer("received-restart");
    let q = f.request("received-restart");
    assert_eq!(f.answer(&q, "trusted-reception-answer").0, 200);
    until("simulated native content observed", || {
        f.state(&q) == "adopted"
    });
    let latest = f
        .call(
            &format!("/v1/requests/{}", q["requestId"].as_str().unwrap()),
            None,
        )
        .1;
    // Explicit trusted-host protocol fixture: this injection is not a claim that
    // the simulated/current Claude protocol supplies remote winner attribution.
    let mut p = json!({"schemaVersion":1,"responseId":"trusted-reception-answer","bindingDigest":latest["bindingDigest"],"received":{"proofId":"trusted-source-fixture","kind":"claude.tool_result","sourceDigest":"b".repeat(64),"position":1},"continued":null,"continuationObservation":"awaiting"});
    for key in agentinbox::reply_progress::IDENTITY {
        p[*key] = latest[*key].clone();
    }
    let response=f.client.post(format!("{}/v1/host/receipt",f.base)).bearer_auth(HOST).json(&json!({"requestId":q["requestId"],"responseId":"trusted-reception-answer","state":"adopted","evidence":{"fixtureOnly":true},"replyProgress":p})).send().unwrap();
    assert_eq!(response.status().as_u16(), 200);
    f.restart_relay();
    f.restart_host();
    let final_q = f
        .call(
            &format!("/v1/requests/{}", q["requestId"].as_str().unwrap()),
            None,
        )
        .1;
    assert_eq!(final_q["state"], "adopted");
    assert!(final_q["replyProgress"]["received"].is_object());
    assert!(final_q["replyProgress"]["continued"].is_null());
    assert_eq!(
        final_q["replyProgress"]["continuationObservation"],
        "unknown"
    );
    assert_one_bound_delivery(&output, "received-restart");
}
