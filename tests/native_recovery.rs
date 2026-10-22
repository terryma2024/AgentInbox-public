//! Protocol fixtures exercise recovery; this is not real engine qualification.
use agentinbox::{
    adapters::codex,
    host::{Config, reconcile_native_dispatches},
    native_receipt::Source,
    reply_evidence::DispatchBoundary,
    store::Store,
};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
#[test]
fn recovered_native_winner_preserves_original_ids_and_never_replays_answer() {
    let dir = std::env::temp_dir().join(format!("native-recovery-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let native = dir.join("native");
    fs::create_dir(&native).unwrap();
    fs::set_permissions(&native, fs::Permissions::from_mode(0o700)).unwrap();
    let write = |p: &std::path::Path, v: &Value| {
        fs::write(p, v.to_string()).unwrap();
        fs::set_permissions(p, fs::Permissions::from_mode(0o600)).unwrap();
    };
    write(
        &native.join("manifest.json"),
        &json!({"schemaVersion":1,"nativePid":42,"nativeInstanceId":"11111111-1111-4111-8111-111111111111"}),
    );
    let callback = json!({"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"fixture-session","turnId":"fixture-turn","itemId":"fixture-call","questions":[{"id":"q","question":"Pick","options":[{"label":"Alpha"},{"label":"Beta"}]}]}});
    let mut q =
        codex::product_request(&callback, "fixture-host", "fixture-runtime", 100, 600).unwrap();
    q["native"]["rolloutPath"] = json!(dir.join("original.jsonl"));
    let answer = json!({"requestId":q["requestId"],"responseId":"fixture-answer","revision":1,"optionIds":["q0-o1"]});
    let source = Source::connect(&native, 42).unwrap();
    let dispatch = source.dispatch(&q);
    write(
        &native.join(format!("dispatch-{}.json", dispatch.dispatch_id)),
        &json!({"schemaVersion":1,"nativePid":42,"nativeInstanceId":source.manifest.native_instance_id,"dispatchId":dispatch.dispatch_id,"bindingDigest":dispatch.binding_digest,"callback":callback,"result":codex::response(&callback,&q,&answer).unwrap()["result"]}),
    );
    let mut f = fs::File::create(dir.join("original.jsonl")).unwrap();
    for row in [
        json!({"type":"session_meta","payload":{"id":"fixture-session"}}),
        json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"fixture-turn"}}),
        json!({"type":"response_item","payload":{"type":"function_call_output","call_id":"fixture-call","output":codex::response(&callback,&q,&answer).unwrap()["result"].to_string()}}),
        json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"fixture-turn"}}),
    ] {
        writeln!(f, "{row}").unwrap();
    }
    drop(f);
    write(
        &dir.join(format!("dispatch-{}", q["requestId"].as_str().unwrap())),
        &json!({"requestId":q["requestId"],"responseId":"fixture-answer","request":q,"callback":callback,"response":answer,"boundary":DispatchBoundary::capture(""),"nativeSource":source,"nativeDispatch":dispatch}),
    );
    let store = Arc::new(Store::open(":memory:").unwrap());
    store.create("fixture-host", q.clone(), 100).unwrap();
    store
        .respond("fixture-device", answer.clone(), 101)
        .unwrap();
    store
        .claim_one("fixture-host", q["requestId"].as_str().unwrap(), 102)
        .unwrap();
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}", server.server_addr().to_ip().unwrap());
    let stop = Arc::new(AtomicBool::new(false));
    let stopping = stop.clone();
    let db = store.clone();
    let id = q["requestId"].as_str().unwrap().to_owned();
    let worker = std::thread::spawn(move || {
        let mut writes = 0;
        while !stopping.load(Ordering::Relaxed) {
            let Some(mut req) = server.recv_timeout(Duration::from_millis(30)).unwrap() else {
                continue;
            };
            let result = if req.url() == format!("/v1/requests/{id}") {
                db.get(&id, true).unwrap()
            } else if req.url() == "/v1/capabilities" {
                json!({"replyProgressVersion":1})
            } else {
                assert_eq!(
                    req.url(),
                    "/v1/host/receipt",
                    "recovery may only read and deliver receipts"
                );
                writes += 1;
                let body: Value = serde_json::from_reader(req.as_reader()).unwrap();
                db.receipt("fixture-host", body, 103).unwrap()
            };
            req.respond(tiny_http::Response::from_string(result.to_string()))
                .unwrap();
        }
        writes
    });
    let c:Config=serde_json::from_value(json!({"hostId":"fixture-host","relayUrl":url,"tokenFile":dir.join("fixture-key"),"stateDir":dir,"ipcSocket":dir.join("hook.sock"),"nativeReceiptDir":native,"scopes":[dir]})).unwrap();
    reconcile_native_dispatches(&c, "public-fixture-key-not-a-credential").unwrap();
    reconcile_native_dispatches(&c, "public-fixture-key-not-a-credential").unwrap();
    let result = store.get(q["requestId"].as_str().unwrap(), false).unwrap();
    assert_eq!(result["responseId"], "fixture-answer");
    assert!(result["replyProgress"]["received"].is_object());
    assert!(result["replyProgress"]["continued"].is_object());
    assert!(
        store
            .claim_one("fixture-host", q["requestId"].as_str().unwrap(), 104)
            .unwrap()
            .is_empty()
    );
    // An engine restart replaces the live manifest. Saved native winner evidence
    // still belongs to the old immutable dispatch; recovery does not attach a callback.
    write(
        &native.join("manifest.json"),
        &json!({"schemaVersion":1,"nativePid":84,"nativeInstanceId":"22222222-2222-4222-8222-222222222222"}),
    );
    reconcile_native_dispatches(&c, "public-fixture-key-not-a-credential").unwrap();
    // A fresh engine uses a fresh receipt directory; old immutable evidence stays
    // pinned to the saved original source, never the new engine's callback.
    let next_native = dir.join("next-native");
    fs::create_dir(&next_native).unwrap();
    fs::set_permissions(&next_native, fs::Permissions::from_mode(0o700)).unwrap();
    write(
        &next_native.join("manifest.json"),
        &json!({"schemaVersion":1,"nativePid":126,"nativeInstanceId":"33333333-3333-4333-8333-333333333333"}),
    );
    let mut next_config = c.clone();
    next_config.native_receipt_dir = Some(next_native);
    reconcile_native_dispatches(&next_config, "public-fixture-key-not-a-credential").unwrap();
    // A dispatch made while the rollout was unreadable has no prefix boundary.
    // It remains unknown, but must not prevent the next host startup.
    let ledger = dir.join(format!("dispatch-{}", q["requestId"].as_str().unwrap()));
    let mut saved: Value = serde_json::from_slice(&fs::read(&ledger).unwrap()).unwrap();
    saved["boundary"] = Value::Null;
    write(&ledger, &saved);
    assert!(reconcile_native_dispatches(&c, "public-fixture-key-not-a-credential").is_ok());
    stop.store(true, Ordering::Relaxed);
    assert_eq!(worker.join().unwrap(), 4);
    fs::remove_dir_all(dir).unwrap();
}
