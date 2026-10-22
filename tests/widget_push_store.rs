use agentinbox::{
    store::Store,
    widget_push::{MAX_WIDGET_ATTEMPTS, WidgetDelivery, WidgetFailure},
};
use rusqlite::Connection;
use serde_json::{Value, json};
fn question(id: &str) -> Value {
    json!({"requestId":id,"revision":1,"expiresAt":2000,"kind":"choice","hostId":"h","engine":"codex","runtimeId":"r","sessionId":"s","turnId":"t","nativeRequestId":id,"itemId":id,"title":"secret body","body":"private prompt","options":[{"id":"a","label":"甲"}],"multiSelect":false})
}
fn answer(id: &str) -> Value {
    json!({"requestId":id,"responseId":format!("response-{id}"),"revision":1,"optionIds":["a"],"text":null,"answers":{}})
}
fn temp() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("widget-store-{}.sqlite", uuid::Uuid::new_v4()))
}
fn register(s: &Store) {
    s.widget_token("d", &"a".repeat(64), "sandbox", true, 1000, 1000)
        .unwrap();
}
#[test]
fn same_token_provider_registration_does_not_loop_or_reset_retry() {
    let s = Store::open(":memory:").unwrap();
    register(&s);
    let j = s.widget_batch(1002).unwrap().remove(0);
    s.widget_result(&j, WidgetDelivery::Retry(WidgetFailure::Transport), 1003)
        .unwrap();
    s.widget_token("d", &"A".repeat(64), "sandbox", true, 1004, 1004)
        .unwrap();
    assert!(s.widget_batch(1005).unwrap().is_empty());
    let retry = s.widget_batch(1100).unwrap().remove(0);
    assert_eq!(retry.generation, j.generation);
    assert_eq!(retry.attempts, 1);
    assert_eq!(retry.token_version, j.token_version);
    s.device_token("d", &"b".repeat(64), "sandbox").unwrap();
    s.invalidate_push_token(&"b".repeat(64)).unwrap();
    assert!(s.widget_job_authorized(&retry, 1100).unwrap());
}
#[test]
fn real_request_transitions_coalesce_and_duplicate_calls_do_not_enqueue() {
    let s = Store::open(":memory:").unwrap();
    register(&s);
    s.create("h", question("q"), 1000).unwrap();
    let created = s.widget_batch(1002).unwrap().remove(0);
    s.create("h", question("q"), 1001).unwrap();
    assert_eq!(
        s.widget_batch(1002).unwrap()[0].generation,
        created.generation
    );
    s.respond("d", answer("q"), 1003).unwrap();
    let submitted = s.widget_batch(1010).unwrap().remove(0);
    assert_eq!(submitted.generation, created.generation + 1);
    s.respond("d", answer("q"), 1004).unwrap();
    assert_eq!(
        s.widget_batch(1010).unwrap()[0].generation,
        submitted.generation
    );
    s.claim_one("h", "q", 1005).unwrap();
    let receipt = json!({"requestId":"q","responseId":"response-q","state":"adopted","evidence":"native result"});
    s.receipt("h", receipt.clone(), 1006).unwrap();
    let adopted = s.widget_batch(1010).unwrap().remove(0);
    assert_eq!(adopted.generation, submitted.generation + 1);
    s.receipt("h", receipt, 1007).unwrap();
    assert_eq!(
        s.widget_batch(1010).unwrap()[0].generation,
        adopted.generation
    );
}
#[test]
fn old_success_cannot_ack_a_new_generation_and_old_failure_cannot_reschedule_it() {
    let s = Store::open(":memory:").unwrap();
    register(&s);
    let old = s.widget_batch(1002).unwrap().remove(0);
    s.create("h", question("q"), 1003).unwrap();
    let new = s.widget_batch(1005).unwrap().remove(0);
    assert!(new.generation > old.generation);
    s.widget_result(&old, WidgetDelivery::Delivered, 1005)
        .unwrap();
    s.widget_result(&old, WidgetDelivery::Retry(WidgetFailure::Transport), 1006)
        .unwrap();
    let pending = s.widget_batch(1010).unwrap().remove(0);
    assert_eq!(pending.generation, new.generation);
    assert_eq!(pending.attempts, 0);
    s.widget_result(&pending, WidgetDelivery::Delivered, 1010)
        .unwrap();
    assert!(s.widget_batch(1015).unwrap().is_empty());
}
#[test]
fn token_rotation_aba_and_active_changes_invalidate_old_snapshots() {
    let s = Store::open(":memory:").unwrap();
    register(&s);
    let old = s.widget_batch(1002).unwrap().remove(0);
    s.widget_token("d", &"b".repeat(64), "sandbox", true, 1003, 1003)
        .unwrap();
    s.widget_token("d", &"a".repeat(64), "sandbox", true, 1004, 1004)
        .unwrap();
    assert!(!s.widget_job_authorized(&old, 1006).unwrap());
    s.widget_result(&old, WidgetDelivery::Unregistered, 1006)
        .unwrap();
    let new = s.widget_batch(1007).unwrap().remove(0);
    assert!(new.token_version > old.token_version);
    assert!(s.widget_job_authorized(&new, 1007).unwrap());
    s.widget_token("d", &"a".repeat(64), "sandbox", false, 1008, 1008)
        .unwrap();
    assert!(!s.widget_job_authorized(&new, 1010).unwrap());
    assert!(s.widget_batch(1010).unwrap().is_empty());
    s.widget_result(&new, WidgetDelivery::Delivered, 1011)
        .unwrap();
    s.widget_token("d", &"a".repeat(64), "sandbox", true, 1012, 1012)
        .unwrap();
    assert_eq!(s.widget_batch(1014).unwrap().len(), 1);
}
#[test]
fn expiration_worker_refreshes_even_without_a_phone_fetch() {
    let s = Store::open(":memory:").unwrap();
    register(&s);
    s.create("h", question("q"), 1000).unwrap();
    let before = s.widget_batch(1002).unwrap().remove(0);
    s.widget_result(&before, WidgetDelivery::Delivered, 1002)
        .unwrap();
    let after = s.widget_batch(2001).unwrap();
    assert_eq!(s.get("q", false).unwrap()["state"], "expired");
    assert!(after.is_empty(), "coalesce first");
    let after = s.widget_batch(2003).unwrap().remove(0);
    assert!(after.generation > before.generation);
}
#[test]
fn restart_recovers_unknown_and_legacy_state_changes_without_replaying_agent_answers() {
    let path = temp();
    let before;
    {
        let s = Store::open(&path).unwrap();
        register(&s);
        s.create("h", question("q"), 1000).unwrap();
        s.respond("d", answer("q"), 1001).unwrap();
        s.claim_one("h", "q", 1002).unwrap();
        before = s.widget_batch(1010).unwrap().remove(0);
        s.widget_result(&before, WidgetDelivery::Delivered, 1010)
            .unwrap();
    }
    {
        let s = Store::open(&path).unwrap();
        assert_eq!(s.get("q", false).unwrap()["state"], "unknown");
        assert!(s.claim_one("h", "q", 1011).unwrap().is_empty());
        let recovered = s
            .widget_batch(agentinbox::model::now() + 10)
            .unwrap()
            .remove(0);
        assert!(recovered.generation > before.generation);
        s.widget_result(
            &recovered,
            WidgetDelivery::Delivered,
            agentinbox::model::now() + 10,
        )
        .unwrap();
    }
    {
        let db = Connection::open(&path).unwrap();
        db.execute("UPDATE requests SET state='invalidated' WHERE id='q'", [])
            .unwrap();
    }
    let s = Store::open(&path).unwrap();
    let restored = s
        .widget_batch(agentinbox::model::now() + 30)
        .unwrap()
        .remove(0);
    assert_eq!(s.get("q", false).unwrap()["state"], "invalidated");
    assert!(s.claim_one("h", "q", 1201).unwrap().is_empty());
    assert!(restored.generation > before.generation);
    std::fs::remove_file(path).unwrap();
}
#[test]
fn bounded_retries_survive_restart_and_same_token_registration_cannot_revive_failed_generation() {
    let path = temp();
    let s = Store::open(&path).unwrap();
    register(&s);
    let mut time = 1002;
    for attempt in 0..MAX_WIDGET_ATTEMPTS {
        let j = s.widget_batch(time).unwrap().remove(0);
        assert_eq!(j.attempts, attempt);
        s.widget_result(&j, WidgetDelivery::Retry(WidgetFailure::ServerError), time)
            .unwrap();
        time += 4000;
    }
    assert!(s.widget_batch(time).unwrap().is_empty());
    s.widget_token("d", &"a".repeat(64), "sandbox", true, time, time)
        .unwrap();
    drop(s);
    let s = Store::open(&path).unwrap();
    assert!(s.widget_batch(time + 5000).unwrap().is_empty());
    std::fs::remove_file(path).unwrap();
}
#[test]
fn legacy_revocation_blocks_fetched_jobs_and_operator_revoke_updates_widget_tables_atomically() {
    let path = temp();
    let s = Store::open(&path).unwrap();
    s.add_pair_code("public-code-fixture", 1000).unwrap();
    let d = s.pair("public-code-fixture", "fixture", 1001).unwrap();
    let id = d["deviceId"].as_str().unwrap();
    s.widget_token(id, &"a".repeat(64), "sandbox", true, 1001, 1001)
        .unwrap();
    let job = s.widget_batch(1003).unwrap().remove(0);
    {
        let db = Connection::open(&path).unwrap();
        db.execute("INSERT INTO revoked_credentials VALUES(?1)", [id])
            .unwrap();
    }
    assert!(!s.widget_job_authorized(&job, 1004).unwrap());
    s.widget_result(&job, WidgetDelivery::Delivered, 1004)
        .unwrap();
    assert!(s.widget_batch(1005).unwrap().is_empty());
    assert_eq!(
        s.widget_token(id, &"b".repeat(64), "sandbox", true, 1005, 1005)
            .unwrap_err()
            .status,
        401
    );
    std::fs::remove_file(path).unwrap();
}
#[test]
fn revocation_cancellation_failure_rolls_back_existing_and_widget_writes() {
    let path = temp();
    let s = Store::open(&path).unwrap();
    s.add_pair_code("public-code-fixture", 1000).unwrap();
    let d = s.pair("public-code-fixture", "fixture", 1001).unwrap();
    let id = d["deviceId"].as_str().unwrap();
    s.widget_token(id, &"a".repeat(64), "sandbox", true, 1001, 1001)
        .unwrap();
    let db = Connection::open(&path).unwrap();
    db.execute_batch("CREATE TRIGGER fail_widget_cancel BEFORE UPDATE OF state ON widget_updates WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'fixture-only'); END;").unwrap();
    assert!(s.revoke_device(id).is_err());
    assert!(!s.is_revoked(id).unwrap());
    assert!(
        s.widget_job_authorized(&s.widget_batch(1004).unwrap()[0], 1004)
            .unwrap()
    );
    std::fs::remove_file(path).unwrap();
}

#[test]
fn permanent_topic_failure_stays_blocked_across_real_changes_and_registration_revisions() {
    let s = Store::open(":memory:").unwrap();
    register(&s);
    let j = s.widget_batch(1002).unwrap().remove(0);
    s.widget_result(
        &j,
        WidgetDelivery::Rejected(WidgetFailure::TopicDisallowed),
        1002,
    )
    .unwrap();
    s.create("h", question("new"), 1003).unwrap();
    s.widget_token("d", &"a".repeat(64), "sandbox", true, 2000, 1004)
        .unwrap();
    s.widget_token("d", &"b".repeat(64), "sandbox", true, 2001, 1005)
        .unwrap();
    s.widget_token("d", &"b".repeat(64), "sandbox", false, 2002, 1006)
        .unwrap();
    s.widget_token("d", &"b".repeat(64), "sandbox", true, 2003, 1007)
        .unwrap();
    assert!(s.widget_batch(1010).unwrap().is_empty());
    assert_eq!(s.widget_registration_revision("d").unwrap(), 2003);
}
#[test]
fn late_revision_and_same_revision_conflict_are_zero_write_and_higher_same_body_keeps_job_snapshot()
{
    let path = temp();
    let s = Store::open(&path).unwrap();
    s.widget_token("d", &"b".repeat(64), "sandbox", true, 2, 1000)
        .unwrap();
    let before = s.widget_batch(1002).unwrap().remove(0);
    s.widget_result(
        &before,
        WidgetDelivery::Retry(WidgetFailure::Transport),
        1003,
    )
    .unwrap();
    let db = Connection::open(&path).unwrap();
    let snapshot = |db: &Connection| {
        db.query_row("SELECT t.token,t.version,t.registration_revision,u.generation,u.attempts,u.next FROM widget_tokens t JOIN widget_updates u ON u.device=t.device WHERE t.device='d'",[],|r|Ok((r.get::<_,String>(0)?,r.get::<_,i64>(1)?,r.get::<_,i64>(2)?,r.get::<_,i64>(3)?,r.get::<_,i64>(4)?,r.get::<_,i64>(5)?))).unwrap()
    };
    let saved = snapshot(&db);
    assert_eq!(
        s.widget_token("d", &"a".repeat(64), "sandbox", true, 1, 1004)
            .unwrap_err()
            .status,
        409
    );
    assert_eq!(
        s.widget_token("d", &"a".repeat(64), "sandbox", true, 2, 1004)
            .unwrap_err()
            .status,
        409
    );
    assert_eq!(snapshot(&db), saved);
    s.widget_token("d", &"B".repeat(64), "sandbox", true, 3, 1005)
        .unwrap();
    let after = snapshot(&db);
    assert_eq!(after.0, saved.0);
    assert_eq!(after.1, saved.1);
    assert_eq!(after.2, 3);
    assert_eq!((after.3, after.4, after.5), (saved.3, saved.4, saved.5));
    std::fs::remove_file(path).unwrap();
}
#[test]
fn failed_widget_enqueue_rolls_back_original_request_and_response_transactions() {
    let path = temp();
    let s = Store::open(&path).unwrap();
    register(&s);
    let db = Connection::open(&path).unwrap();
    db.execute_batch("CREATE TRIGGER fail_widget_enqueue BEFORE UPDATE OF generation ON widget_updates BEGIN SELECT RAISE(ABORT,'fixture enqueue failure'); END;").unwrap();
    assert!(s.create("h", question("q"), 1000).is_err());
    assert_eq!(
        db.query_row("SELECT count(*) FROM requests", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    db.execute_batch("DROP TRIGGER fail_widget_enqueue")
        .unwrap();
    s.create("h", question("q"), 1001).unwrap();
    db.execute_batch("CREATE TRIGGER fail_widget_enqueue BEFORE UPDATE OF generation ON widget_updates BEGIN SELECT RAISE(ABORT,'fixture enqueue failure'); END;").unwrap();
    assert!(s.respond("d", answer("q"), 1002).is_err());
    assert_eq!(s.get("q", false).unwrap()["state"], "pending");
    assert_eq!(
        db.query_row("SELECT count(*) FROM responses", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    std::fs::remove_file(path).unwrap();
}
#[test]
fn early_widget_schema_migrates_revision_and_legacy_tables_are_not_changed() {
    let path = temp();
    {
        let s = Store::open(&path).unwrap();
        register(&s);
        let db = Connection::open(&path).unwrap();
        db.execute_batch("ALTER TABLE widget_tokens DROP COLUMN registration_revision")
            .unwrap();
    }
    let s = Store::open(&path).unwrap();
    assert_eq!(s.widget_registration_revision("d").unwrap(), 0);
    let before = s.widget_batch(1100).unwrap().remove(0);
    s.widget_token("d", &"a".repeat(64), "sandbox", true, 1, 1101)
        .unwrap();
    let after = s.widget_batch(1102).unwrap().remove(0);
    assert_eq!(after.generation, before.generation);
    assert_eq!(after.token_version, before.token_version);
    let db = Connection::open(&path).unwrap();
    for (table, expected) in [
        ("devices", vec!["id", "token", "environment", "active"]),
        (
            "responses",
            vec!["id", "request", "device", "json", "claimed"],
        ),
        (
            "outbox",
            vec![
                "id", "request", "device", "state", "attempts", "next", "error",
            ],
        ),
    ] {
        let mut statement = db
            .prepare("SELECT name FROM pragma_table_info(?1)")
            .unwrap();
        let columns = statement
            .query_map([table], |r| r.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(columns, expected);
    }
    std::fs::remove_file(path).unwrap();
}
#[test]
fn duplicate_failure_result_does_not_consume_second_retry_or_reschedule_a_fresher_attempt() {
    let s = Store::open(":memory:").unwrap();
    register(&s);
    let j = s.widget_batch(1002).unwrap().remove(0);
    s.widget_result(&j, WidgetDelivery::Retry(WidgetFailure::Transport), 1003)
        .unwrap();
    s.widget_result(&j, WidgetDelivery::Retry(WidgetFailure::Transport), 1010)
        .unwrap();
    let next = s.widget_batch(1033).unwrap().remove(0);
    assert_eq!(next.attempts, 1);
    assert!(!s.widget_job_authorized(&j, 1033).unwrap());
}

#[test]
fn odd_hex_is_rejected_before_registration_version_or_queue_changes() {
    let s = Store::open(":memory:").unwrap();
    s.widget_token("d", &"a".repeat(64), "sandbox", true, 1, 1000)
        .unwrap();
    let j = s.widget_batch(1002).unwrap().remove(0);
    assert_eq!(
        s.widget_token("d", &"b".repeat(33), "sandbox", true, 2, 1003)
            .unwrap_err()
            .status,
        400
    );
    assert_eq!(s.widget_registration_revision("d").unwrap(), 1);
    assert!(s.widget_job_authorized(&j, 1004).unwrap());
}
