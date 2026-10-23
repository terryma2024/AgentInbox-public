use agentinbox::store::Store;
use serde_json::{Value, json};

fn start(s: &Store, device: &str, id: &str, at: i64) -> Value {
    s.start_diagnostic(device, &json!({"testId":id,"hostId":"fixture-host"}), at)
        .unwrap()
}

#[test]
fn missing_and_stale_capture_observations_never_pass_from_a_heartbeat() {
    let s = Store::open(":memory:").unwrap();
    s.heartbeat("fixture-host", 100).unwrap();
    let snapshot = s.diagnostic_snapshot("fixture-device", 101).unwrap();
    assert_eq!(snapshot["hosts"][0]["online"], true);
    assert!(snapshot["hosts"][0]["observation"].is_null());
    s.diagnostic_heartbeat("fixture-host", &json!({"codex":"ready","scanAt":100,"claude":"unobserved","reconciled":true,"draining":false,"private":"fixture-sensitive-body"}), 102).unwrap();
    let snapshot = s.diagnostic_snapshot("fixture-device", 103).unwrap();
    assert_eq!(snapshot["hosts"][0]["observation"]["codex"], "ready");
    assert!(snapshot["hosts"][0]["observation"].get("private").is_none());
    assert!(!snapshot.to_string().contains("fixture-sensitive-body"));
    assert_eq!(
        s.diagnostic_snapshot("fixture-device", 133).unwrap()["hosts"][0]["online"],
        false
    );
    assert!(
        s.diagnostic_heartbeat(
            "fixture-host",
            &json!({"codex":"secret-arbitrary-error"}),
            104
        )
        .is_err()
    );
}

#[test]
fn tests_are_device_owned_idempotent_and_claimed_once_with_bounded_lifetime() {
    let s = Store::open(":memory:").unwrap();
    start(&s, "fixture-device", "fixture-test", 100);
    assert_eq!(
        start(&s, "fixture-device", "fixture-test", 101)["expiresAt"],
        280
    );
    assert!(
        s.diagnostic_test("other-device", "fixture-test", 101)
            .is_err()
    );
    assert!(
        s.start_diagnostic(
            "other-device",
            &json!({"testId":"fixture-test","hostId":"fixture-host"}),
            101
        )
        .is_err()
    );
    assert!(
        s.start_diagnostic(
            "fixture-device",
            &json!({"testId":"other-test","hostId":"fixture-host"}),
            101
        )
        .is_err()
    );
    assert!(s.claim_diagnostic("other-host", 101).unwrap()["test"].is_null());
    assert_eq!(
        s.claim_diagnostic("fixture-host", 101).unwrap()["test"]["testId"],
        "fixture-test"
    );
    assert!(s.claim_diagnostic("fixture-host", 102).unwrap()["test"].is_null());
    assert!(
        s.update_diagnostic(
            "other-host",
            &json!({"testId":"fixture-test","phase":"unsupported"}),
            102
        )
        .is_err()
    );
    assert_eq!(
        s.diagnostic_test("fixture-device", "fixture-test", 281)
            .unwrap()["phase"],
        "expired"
    );
    assert!(
        s.update_diagnostic(
            "fixture-host",
            &json!({"testId":"fixture-test","phase":"starting"}),
            281
        )
        .is_err()
    );
}

fn diagnostic_request(s: &Store) -> Value {
    let q = json!({"requestId":"fixture-request","hostId":"fixture-host","engine":"codex","runtimeId":"fixture-runtime","sessionId":"fixture-session","turnId":"fixture-turn","nativeRequestId":"fixture-native","itemId":"fixture-item","revision":1,"expiresAt":270,"kind":"choice","title":"自检测试","body":"请选择测试回复","options":[{"id":"ok","label":"确认测试"}],"multiSelect":false,"diagnosticTestId":"fixture-test"});
    s.create("fixture-host", q, 102).unwrap();
    s.get("fixture-request", false).unwrap()
}

#[test]
fn test_requests_are_hidden_from_normal_inbox_and_only_push_to_the_initiator() {
    let s = Store::open(":memory:").unwrap();
    s.device_token("fixture-device", &"a".repeat(64), "sandbox")
        .unwrap();
    s.device_token("other-device", &"b".repeat(64), "sandbox")
        .unwrap();
    start(&s, "fixture-device", "fixture-test", 100);
    s.claim_diagnostic("fixture-host", 101).unwrap();
    diagnostic_request(&s);
    assert!(s.list(103).unwrap().is_empty());
    let batch = s.push_batch(103).unwrap();
    assert_eq!(batch.len(), 1);
    assert_eq!(batch[0]["token"], "a".repeat(64));
    assert_eq!(
        s.diagnostic_test("fixture-device", "fixture-test", 103)
            .unwrap()["request"]["requestId"],
        "fixture-request"
    );
}

#[test]
fn push_acceptance_and_legacy_adoption_never_confirm_original_reception() {
    let s = Store::open(":memory:").unwrap();
    s.device_token("fixture-device", &"a".repeat(64), "sandbox")
        .unwrap();
    start(&s, "fixture-device", "fixture-test", 100);
    s.claim_diagnostic("fixture-host", 101).unwrap();
    let q = diagnostic_request(&s);
    let push = s.push_batch(103).unwrap();
    s.push_result(push[0]["id"].as_i64().unwrap(), true, false, 103)
        .unwrap();
    let status = s
        .diagnostic_test("fixture-device", "fixture-test", 104)
        .unwrap();
    assert_eq!(status["push"], "accepted");
    assert_eq!(status["received"], false);
    let a = json!({"requestId":"fixture-request","responseId":"fixture-answer","revision":1,"optionIds":["ok"],"bindingDigest":q["bindingDigest"]});
    s.respond("fixture-device", a, 104).unwrap();
    s.claim_one("fixture-host", "fixture-request", 104).unwrap();
    s.receipt("fixture-host", json!({"requestId":"fixture-request","responseId":"fixture-answer","state":"adopted","evidence":{"nativeToolResult":true}}), 105).unwrap();
    let status = s
        .diagnostic_test("fixture-device", "fixture-test", 106)
        .unwrap();
    assert_eq!(status["submitted"], true);
    assert_eq!(status["received"], false);
    assert_eq!(status["continued"], false);
}

#[test]
fn arbitrary_host_result_cannot_forge_reception_or_leak_error_text() {
    let s = Store::open(":memory:").unwrap();
    start(&s, "fixture-device", "fixture-test", 100);
    s.claim_diagnostic("fixture-host", 101).unwrap();
    assert!(
        s.update_diagnostic(
            "fixture-host",
            &json!({"testId":"fixture-test","phase":"passed","received":true}),
            102
        )
        .is_err()
    );
    s.update_diagnostic("fixture-host", &json!({"testId":"fixture-test","phase":"failed","code":"nativeStartFailed","error":"fixture-private-raw-error"}), 102).unwrap();
    let status = s
        .diagnostic_test("fixture-device", "fixture-test", 103)
        .unwrap();
    assert_eq!(status["code"], "nativeStartFailed");
    assert!(!status.to_string().contains("fixture-private-raw-error"));
}

#[test]
fn push_only_is_independent_of_host_support_and_does_not_block_reply_test() {
    let s = Store::open(":memory:").unwrap();
    let push = s
        .start_diagnostic(
            "fixture-device",
            &json!({"testId":"fixture-push-test","hostId":"fixture-host","mode":"push"}),
            100,
        )
        .unwrap();
    assert_eq!(push["mode"], "push");
    assert!(push["request"].is_object());
    assert_eq!(push["received"], false);
    assert!(s.claim_diagnostic("fixture-host", 101).unwrap()["test"].is_null());
    start(&s, "fixture-device", "fixture-test", 101);
    assert_eq!(
        s.claim_diagnostic("fixture-host", 102).unwrap()["test"]["testId"],
        "fixture-test"
    );
}

#[test]
fn other_devices_cannot_answer_or_backfill_pushes_for_a_diagnostic() {
    let s = Store::open(":memory:").unwrap();
    start(&s, "fixture-device", "fixture-test", 100);
    s.claim_diagnostic("fixture-host", 101).unwrap();
    let q = diagnostic_request(&s);
    assert!(
        s.authorize_diagnostic_request("fixture-request", "other-device")
            .is_err()
    );
    assert!(s.respond("other-device",json!({"requestId":"fixture-request","responseId":"fixture-answer","revision":1,"optionIds":["ok"],"bindingDigest":q["bindingDigest"]}),103).is_err());
    s.device_token("other-device", &"a".repeat(64), "sandbox")
        .unwrap();
    assert!(s.push_batch(103).unwrap().is_empty());
}

#[test]
fn push_creation_repairs_a_committed_job_without_request_after_restart() {
    let path = std::env::temp_dir().join(format!("diagnostic-gap-{}.sqlite", uuid::Uuid::new_v4()));
    {
        let _ = Store::open(&path).unwrap();
    }
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute("INSERT INTO diagnostic_tests(id,device,host,created,expires,phase,mode) VALUES('fixture-gap','fixture-device','fixture-host',100,280,'starting','push')",[]).unwrap();
    drop(db);
    let s = Store::open(&path).unwrap();
    let status = s
        .start_diagnostic(
            "fixture-device",
            &json!({"testId":"fixture-gap","hostId":"fixture-host","mode":"push"}),
            110,
        )
        .unwrap();
    assert!(
        status["request"].is_object(),
        "A committed push job must repair its absent request"
    );
    assert_eq!(status["expiresAt"], 280);
    assert_eq!(status["request"]["expiresAt"], 280);
    let again = s
        .start_diagnostic(
            "fixture-device",
            &json!({"testId":"fixture-gap","hostId":"fixture-host","mode":"push"}),
            111,
        )
        .unwrap();
    assert_eq!(
        again["request"]["requestId"],
        status["request"]["requestId"]
    );
    drop(s);
    let _ = std::fs::remove_file(path);
}
