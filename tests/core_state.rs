use agentinbox::store::Store;
use serde_json::{Value, json};
fn request(id: &str) -> Value {
    json!({"requestId":id,"revision":1,"expiresAt":2000,"state":"pending","kind":"choice","hostId":"h","engine":"codex","runtimeId":"r","sessionId":"s","turnId":"t","nativeRequestId":id,"itemId":null,"title":"选择","body":"","options":[{"id":"a","label":"甲"}],"multiSelect":false,"createdAt":1000,"updatedAt":1000,"native":{"binding":"secret"}})
}
fn answer(id: &str, rid: &str) -> Value {
    json!({"requestId":id,"responseId":rid,"revision":1,"optionIds":["a"],"text":null,"answers":{}})
}
#[test]
fn rejects_stale_and_bad_options() {
    let s = Store::open(":memory:").unwrap();
    s.create("h", request("q"), 1000).unwrap();
    let mut a = answer("q", "a");
    a["revision"] = json!(2);
    assert!(s.respond("d", a, 1001).is_err());
    let mut a = answer("q", "b");
    a["optionIds"] = json!(["missing"]);
    assert!(s.respond("d", a, 1001).is_err());
    assert!(s.respond("d", answer("q", "c"), 2000).is_err());
}
#[test]
fn dedup_conflict_single_claim() {
    let s = Store::open(":memory:").unwrap();
    s.create("h", request("q"), 1000).unwrap();
    let a = answer("q", "a");
    s.respond("d", a.clone(), 1001).unwrap();
    assert!(s.respond("d", a.clone(), 1001).is_ok());
    let mut changed = a;
    changed["text"] = json!("other");
    assert!(s.respond("d", changed, 1001).is_err());
    assert!(s.respond("d", answer("q", "b"), 1001).is_err());
    assert_eq!(s.claim("wrong", 1002).unwrap().len(), 0);
    assert_eq!(s.claim("h", 1002).unwrap().len(), 1);
    assert_eq!(s.claim("h", 1002).unwrap().len(), 0);
    assert!(
        s.receipt(
            "wrong",
            json!({"requestId":"q","responseId":"a","state":"adopted","evidence":"native ack"}),
            1003
        )
        .is_err()
    );
    s.receipt(
        "h",
        json!({"requestId":"q","responseId":"a","state":"adopted","evidence":"native ack"}),
        1003,
    )
    .unwrap();
    assert_eq!(s.get("q", false).unwrap()["state"], "adopted");
    assert!(s.respond("d", answer("q", "b"), 1004).is_err());
}
#[test]
fn restart_claimed_is_unknown_unclaimed_survives() {
    let p = std::env::temp_dir().join(format!("inbox-{}.db", uuid::Uuid::new_v4()));
    {
        let s = Store::open(&p).unwrap();
        s.create("h", request("q"), 1000).unwrap();
        s.create("h", request("q2"), 1000).unwrap();
        s.respond("d", answer("q", "a"), 1001).unwrap();
        s.respond("d", answer("q2", "b"), 1001).unwrap();
        assert_eq!(s.claim("h", 1002).unwrap().len(), 2);
    }
    let s = Store::open(&p).unwrap();
    assert_eq!(s.get("q", false).unwrap()["state"], "unknown");
    assert_eq!(s.claim("h", 1003).unwrap().len(), 0);
    std::fs::remove_file(p).unwrap();
}
#[test]
fn concurrent_candidates_only_one_wins() {
    use std::sync::{Arc, Barrier};
    let s = Arc::new(Store::open(":memory:").unwrap());
    s.create("h", request("q"), 1000).unwrap();
    let b = Arc::new(Barrier::new(3));
    let ts: Vec<_> = (0..2)
        .map(|i| {
            let s = s.clone();
            let b = b.clone();
            std::thread::spawn(move || {
                b.wait();
                s.respond("d", answer("q", &format!("a{i}")), 1001).is_ok()
            })
        })
        .collect();
    b.wait();
    assert_eq!(
        ts.into_iter()
            .filter_map(|t| t.join().ok())
            .filter(|x| *x)
            .count(),
        1
    );
}
#[test]
fn no_native_data_device_view() {
    let s = Store::open(":memory:").unwrap();
    s.create("h", request("q"), 1000).unwrap();
    assert!(s.get("q", false).unwrap().get("native").is_none());
    assert!(s.create("other", request("q2"), 1000).is_err());
}
#[test]
fn pairing_once_expiry_revocation() {
    let s = Store::open(":memory:").unwrap();
    s.add_pair_code("test-code-only", 1000).unwrap();
    let p = s.pair("test-code-only", "手机", 1001).unwrap();
    let token = p["token"].as_str().unwrap();
    assert!(s.device_credential(token).unwrap().is_some());
    assert!(s.pair("test-code-only", "重复", 1002).is_err());
    s.revoke_device(p["deviceId"].as_str().unwrap()).unwrap();
    assert!(s.device_credential(token).unwrap().is_none());
    s.add_pair_code("expired-code", 1000).unwrap();
    assert!(s.pair("expired-code", "手机", 1600).is_err());
}
#[test]
fn isolated_claim_and_unknown_reconcile() {
    let s = Store::open(":memory:").unwrap();
    for id in ["q", "q2"] {
        s.create("h", request(id), 1000).unwrap();
        s.respond("d", answer(id, &format!("a-{id}")), 1001)
            .unwrap();
    }
    assert_eq!(s.claim_one("h", "q", 1002).unwrap()[0]["requestId"], "q");
    assert_eq!(s.claim_one("h", "q2", 1002).unwrap()[0]["requestId"], "q2");
    s.receipt(
        "h",
        json!({"requestId":"q","responseId":"a-q","state":"unknown","evidence":null}),
        1003,
    )
    .unwrap();
    s.receipt(
        "h",
        json!({"requestId":"q","responseId":"a-q","state":"adopted","evidence":{"native":"exact"}}),
        1004,
    )
    .unwrap();
    assert_eq!(s.get("q", false).unwrap()["state"], "adopted");
}
#[test]
fn token_registration_backfills_pending_outbox_once() {
    let s = Store::open(":memory:").unwrap();
    let now = agentinbox::model::now();
    let mut q = request("q");
    q["expiresAt"] = json!(now + 3600);
    s.create("h", q, now).unwrap();
    s.device_token("d", &"a".repeat(64), "sandbox").unwrap();
    s.device_token("d", &"a".repeat(64), "sandbox").unwrap();
    assert_eq!(s.push_batch(now + 1).unwrap().len(), 1);
    s.revoke_device("d").unwrap();
    assert_eq!(s.push_batch(now + 2).unwrap().len(), 0);
}
#[test]
fn outbox_restart_retry_and_permanent_failure() {
    let p = std::env::temp_dir().join(format!("outbox-{}.db", uuid::Uuid::new_v4()));
    let now = agentinbox::model::now();
    let id;
    {
        let s = Store::open(&p).unwrap();
        s.device_token("d", &"a".repeat(64), "sandbox").unwrap();
        let mut q = request("q");
        q["expiresAt"] = json!(now + 3600);
        s.create("h", q, now).unwrap();
        id = s.push_batch(now + 1).unwrap()[0]["id"].as_i64().unwrap();
        s.push_result(id, false, false, now + 2).unwrap();
        assert_eq!(s.push_batch(now + 10).unwrap().len(), 0);
    }
    let s = Store::open(&p).unwrap();
    assert_eq!(s.push_batch(now + 63).unwrap().len(), 1);
    s.push_result(id, false, true, now + 63).unwrap();
    assert_eq!(s.push_batch(now + 100).unwrap().len(), 0);
    std::fs::remove_file(p).unwrap();
}
#[test]
fn invalid_apns_token_keeps_api_credential() {
    let s = Store::open(":memory:").unwrap();
    s.add_pair_code("pairing-test", 1000).unwrap();
    let d = s.pair("pairing-test", "phone", 1001).unwrap();
    s.device_token(d["deviceId"].as_str().unwrap(), &"a".repeat(64), "sandbox")
        .unwrap();
    s.invalidate_push_token(&"a".repeat(64)).unwrap();
    assert!(
        s.device_credential(d["token"].as_str().unwrap())
            .unwrap()
            .is_some()
    );
}
