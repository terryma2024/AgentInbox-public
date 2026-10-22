use agentinbox::store::Store;
use serde_json::{Value, json};
fn request(id: &str) -> Value {
    json!({"requestId":id,"revision":1,"expiresAt":2000,"kind":"choice","hostId":"h","engine":"codex","runtimeId":"r","sessionId":"s","turnId":"t","nativeRequestId":id,"itemId":"call","title":"选择","body":"","options":[{"id":"a","label":"甲"}],"multiSelect":false})
}
fn answer(id: &str) -> Value {
    json!({"requestId":id,"responseId":format!("answer-{id}"),"revision":1,"optionIds":["a"],"text":null,"answers":{}})
}
fn setup() -> Store {
    let s = Store::open(":memory:").unwrap();
    s.create("h", request("q"), 1000).unwrap();
    s.respond("d", answer("q"), 1001).unwrap();
    s
}
fn proof(kind: &str, position: u64) -> Value {
    json!({"proofId":format!("proof-{position}"),"kind":kind,"sourceDigest":"a".repeat(64),"position":position})
}
fn receipt(s: &Store, continued: bool) -> Value {
    let q = s.get("q", true).unwrap();
    let mut p = json!({"schemaVersion":1,"requestId":"q","responseId":"answer-q","revision":1,"bindingDigest":q["bindingDigest"],"hostId":"h","engine":"codex","runtimeId":"r","sessionId":"s","turnId":"t","nativeRequestId":"q","itemId":"call","received":proof("codex.function_call_output",3),"continued":null,"continuationObservation":"awaiting"});
    if continued {
        p["continued"] = proof("codex.next_item", 4);
        p["continued"]["receivedProofId"] = json!("proof-3");
        p["continuationObservation"] = json!("confirmed");
    }
    json!({"requestId":"q","responseId":"answer-q","state":"adopted","evidence":{"structuredAnswer":true},"replyProgress":p})
}
#[test]
fn submission_is_not_native_reception() {
    let s = setup();
    let q = s.get("q", false).unwrap();
    assert_eq!(q["replyProgress"]["submitted"]["at"], 1001);
    assert!(q["replyProgress"]["received"].is_null());
    assert!(q["bindingDigest"].as_str().is_some_and(|d| d.len() == 64));
    let duplicate = s.respond("d", answer("q"), 1002).unwrap();
    assert_eq!(duplicate["replyProgress"]["submitted"]["at"], 1001);
}
#[test]
fn legacy_adopted_does_not_invent_steps() {
    let s = setup();
    s.claim_one("h", "q", 1002).unwrap();
    s.receipt(
        "h",
        json!({"requestId":"q","responseId":"answer-q","state":"adopted","evidence":"legacy ack"}),
        1003,
    )
    .unwrap();
    let q = s.get("q", false).unwrap();
    assert!(q["replyProgress"]["submitted"].is_object());
    assert!(q["replyProgress"]["received"].is_null());
    assert!(q["replyProgress"]["continued"].is_null());
}
#[test]
fn proof_requires_claim_and_every_original_binding() {
    let s = setup();
    let good = receipt(&s, false);
    assert!(s.receipt("h", good.clone(), 1002).is_err());
    s.claim_one("h", "q", 1002).unwrap();
    for field in [
        "requestId",
        "responseId",
        "bindingDigest",
        "hostId",
        "engine",
        "runtimeId",
        "sessionId",
        "turnId",
        "nativeRequestId",
        "itemId",
    ] {
        let mut bad = good.clone();
        bad["replyProgress"][field] = json!("wrong");
        assert!(s.receipt("h", bad, 1003).is_err(), "accepted wrong {field}");
    }
    for bad in [json!({}), json!("ack"), json!({"proofId":"p"})] {
        let mut r = good.clone();
        r["replyProgress"]["received"] = bad;
        assert!(s.receipt("h", r, 1003).is_err());
    }
}
#[test]
fn continuation_is_cumulative_idempotent_and_redacted() {
    let s = setup();
    s.claim_one("h", "q", 1002).unwrap();
    let high = receipt(&s, true);
    s.receipt("h", high.clone(), 1003).unwrap();
    s.receipt("h", receipt(&s, false), 1004).unwrap();
    s.receipt("h", high, 1005).unwrap();
    let q = s.get("q", false).unwrap();
    assert!(q["replyProgress"]["received"].is_object());
    assert!(q["replyProgress"]["continued"].is_object());
    assert_eq!(q["replyProgress"]["continuationObservation"], "confirmed");
    assert_eq!(q["replyProgress"]["continued"]["at"], 1003);
    assert!(q["replyProgress"]["received"].get("sourceDigest").is_none());
    assert!(s.get("q", true).unwrap()["replyProgress"]["received"]["sourceDigest"].is_string());
}
#[test]
fn conflicting_or_noncausal_proofs_never_advance() {
    let s = setup();
    s.claim_one("h", "q", 1002).unwrap();
    for mutate in [0, 1, 2, 3, 4] {
        let mut r = receipt(&s, true);
        match mutate {
            0 => r["replyProgress"]["continued"]["position"] = json!(2),
            1 => r["replyProgress"]["continued"]["receivedProofId"] = json!("another"),
            2 => r["replyProgress"]["received"]["kind"] = json!("http.ok"),
            3 => r["replyProgress"]["schemaVersion"] = json!(2),
            _ => r["replyProgress"]["received"] = Value::Null,
        }
        assert!(
            s.receipt("h", r, 1003).is_err(),
            "accepted bad proof {mutate}"
        );
    }
    let good = receipt(&s, false);
    s.receipt("h", good.clone(), 1003).unwrap();
    let mut changed = good;
    changed["replyProgress"]["received"]["sourceDigest"] = json!("b".repeat(64));
    assert!(s.receipt("h", changed, 1004).is_err());
}
#[test]
fn reception_survives_restart_and_unknown_continuation() {
    let path = std::env::temp_dir().join(format!("reply-progress-{}.db", uuid::Uuid::new_v4()));
    {
        let s = Store::open(&path).unwrap();
        s.create("h", request("q"), 1000).unwrap();
        s.respond("d", answer("q"), 1001).unwrap();
        s.claim_one("h", "q", 1002).unwrap();
        s.receipt("h", receipt(&s, false), 1003).unwrap();
    }
    let s = Store::open(&path).unwrap();
    let mut r = receipt(&s, false);
    r["replyProgress"]["continuationObservation"] = json!("unknown");
    s.receipt("h", r, 1004).unwrap();
    let q = s.get("q", false).unwrap();
    assert_eq!(q["state"], "adopted");
    assert!(q["replyProgress"]["received"].is_object());
    assert!(q["replyProgress"]["continued"].is_null());
    assert_eq!(s.claim_one("h", "q", 1005).unwrap().len(), 0);
    drop(s);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn same_value_source_uncertainty_never_promotes_native_steps() {
    let s = setup();
    s.claim_one("h", "q", 1002).unwrap();
    s.receipt("h",json!({"requestId":"q","responseId":"answer-q","state":"adopted","evidence":{"exactStructuredAnswer":true},"nativeObservation":"answerSourceUnconfirmed"}),1003).unwrap();
    let q = s.get("q", false).unwrap();
    assert_eq!(
        q["replyProgress"]["nativeObservation"],
        "answerSourceUnconfirmed"
    );
    assert!(q["replyProgress"]["received"].is_null());
    assert!(q["replyProgress"]["continued"].is_null());
}
#[test]
fn progress_recovery_is_host_scoped_and_counts_awaiting_observers() {
    let s = setup();
    s.claim_one("h", "q", 1002).unwrap();
    s.receipt("h", receipt(&s, false), 1003).unwrap();
    assert_eq!(s.incomplete_progress("h").unwrap().len(), 1);
    assert_eq!(s.incomplete_progress("wrong").unwrap().len(), 0);
    assert_eq!(
        s.upgrade_status("h", 1004).unwrap()["awaitingContinuation"],
        1
    );
    s.receipt("h", receipt(&s, true), 1004).unwrap();
    assert_eq!(s.incomplete_progress("h").unwrap().len(), 0);
    assert_eq!(
        s.upgrade_status("h", 1005).unwrap()["awaitingContinuation"],
        0
    );
}

#[test]
fn legacy_upgrade_guard_still_blocks_awaiting_continuation() {
    let s = setup();
    s.claim_one("h", "q", 1002).unwrap();
    s.receipt("h", receipt(&s, false), 1003).unwrap();
    let snapshot = s.upgrade_status("h", 1004).unwrap();
    let legacy_sum = ["pending", "submitting", "unknown"]
        .iter()
        .map(|k| snapshot[*k].as_i64().unwrap())
        .sum::<i64>();
    assert_eq!(
        legacy_sum, 1,
        "old guard must not approve incomplete observation"
    );
}
#[test]
fn source_uncertainty_and_verified_reception_cannot_coexist() {
    let s = setup();
    s.claim_one("h", "q", 1002).unwrap();
    let mut mixed = receipt(&s, false);
    mixed["nativeObservation"] = json!("answerSourceUnconfirmed");
    assert!(s.receipt("h", mixed, 1003).is_err());
    s.receipt("h",json!({"requestId":"q","responseId":"answer-q","state":"adopted","evidence":"content only","nativeObservation":"answerSourceUnconfirmed"}),1003).unwrap();
    s.receipt("h", receipt(&s, false), 1004).unwrap();
    assert!(s.get("q", false).unwrap()["replyProgress"]["nativeObservation"].is_null());
    assert!(s.receipt("h",json!({"requestId":"q","responseId":"answer-q","state":"adopted","evidence":"late observation","nativeObservation":"answerSourceUnconfirmed"}),1005).is_err());
    assert!(s.get("q", false).unwrap()["replyProgress"]["received"].is_object());
}

#[test]
fn supplied_content_fingerprint_must_match_the_immutable_question() {
    let s = Store::open(":memory:").unwrap();
    s.create("h", request("q"), 1000).unwrap();
    let mut bad = answer("q");
    bad["bindingDigest"] = json!("b".repeat(64));
    assert!(s.respond("d", bad, 1001).is_err());
    assert_eq!(s.get("q", false).unwrap()["state"], "pending");
}

#[test]
fn legacy_sql_writes_preserve_new_proofs_and_remain_readable() {
    let path = std::env::temp_dir().join(format!("ainb-legacy-layout-{}.db", uuid::Uuid::new_v4()));
    {
        let s = Store::open(&path).unwrap();
        s.create("h", request("q"), 1000).unwrap();
        s.respond("d", answer("q"), 1001).unwrap();
        s.claim_one("h", "q", 1002).unwrap();
        s.receipt("h", receipt(&s, true), 1003).unwrap();
    }
    {
        let db = rusqlite::Connection::open(&path).unwrap();
        let q = request("legacy-q");
        let a = answer("legacy-q");
        // Exact old table-column contract, including the no-column-list INSERT.
        db.execute(
            "INSERT INTO requests VALUES(?1,?2,?3,'submitting',?4,?5)",
            rusqlite::params![
                "legacy-q",
                "h",
                "legacy-native-binding",
                2000,
                q.to_string()
            ],
        )
        .unwrap();
        db.execute(
            "INSERT INTO responses(id,request,device,json,claimed) VALUES(?1,?2,?3,?4,0)",
            rusqlite::params!["answer-legacy-q", "legacy-q", "d", a.to_string()],
        )
        .unwrap();
    }
    let s = Store::open(&path).unwrap();
    let legacy = s.get("legacy-q", false).unwrap();
    assert!(legacy["replyProgress"]["submitted"].is_object());
    assert!(legacy["replyProgress"]["submitted"]["at"].is_null());
    assert!(legacy["replyProgress"]["received"].is_null());
    assert!(s.get("q", false).unwrap()["replyProgress"]["continued"].is_object());
    assert_eq!(s.claim_one("h", "legacy-q", 1005).unwrap().len(), 1);
    assert_eq!(s.claim_one("h", "legacy-q", 1006).unwrap().len(), 0);
    drop(s);
    std::fs::remove_file(path).unwrap();
}
