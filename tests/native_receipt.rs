use agentinbox::{
    adapters::codex,
    native_receipt::{Dispatch, Source},
};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    path::PathBuf,
};

struct Fixture {
    dir: PathBuf,
    q: Value,
    callback: Value,
    answer: Value,
}
impl Fixture {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("native-receipt-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let callback = json!({"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"fixture-session","turnId":"fixture-turn","itemId":"fixture-call","questions":[{"id":"q","question":"Pick","options":[{"label":"Alpha"},{"label":"Beta"}]}]}});
        let q =
            codex::product_request(&callback, "fixture-host", "fixture-runtime", 100, 600).unwrap();
        let answer = json!({"requestId":q["requestId"],"responseId":"fixture-answer","revision":1,"optionIds":["q0-o1"]});
        let f = Self {
            dir,
            q,
            callback,
            answer,
        };
        f.write("manifest.json", &json!({"schemaVersion":1,"nativePid":42,"nativeInstanceId":"11111111-1111-4111-8111-111111111111"}));
        f
    }
    fn write(&self, name: &str, v: &Value) {
        let p = self.dir.join(name);
        fs::write(&p, v.to_string()).unwrap();
        fs::set_permissions(p, fs::Permissions::from_mode(0o600)).unwrap();
    }
    fn record(&self, source: &Source, dispatch: &Dispatch) -> Value {
        json!({"schemaVersion":1,"nativePid":42,"nativeInstanceId":source.manifest.native_instance_id,"dispatchId":dispatch.dispatch_id,"bindingDigest":dispatch.binding_digest,"callback":self.callback,"result":codex::response(&self.callback,&self.q,&self.answer).unwrap()["result"]})
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}
#[test]
fn original_answer_requires_native_winner_receipt() {
    let f = Fixture::new();
    let s = Source::connect(&f.dir, 42).unwrap();
    let d = s.dispatch(&f.q);
    // A local same-value winner has the exact output but no phone dispatch receipt.
    assert!(s.verify(&d, &f.q, &f.callback, &f.answer).is_none());
    f.write(
        &format!("dispatch-{}.json", d.dispatch_id),
        &f.record(&s, &d),
    );
    assert!(s.verify(&d, &f.q, &f.callback, &f.answer).is_some());
}
#[test]
fn wrong_process_instance_dispatch_binding_callback_or_result_never_attributes() {
    let f = Fixture::new();
    assert!(Source::connect(&f.dir, 43).is_err());
    let s = Source::connect(&f.dir, 42).unwrap();
    let d = s.dispatch(&f.q);
    let path = format!("dispatch-{}.json", d.dispatch_id);
    for field in [
        "schemaVersion",
        "nativePid",
        "nativeInstanceId",
        "dispatchId",
        "bindingDigest",
        "callback",
        "result",
    ] {
        let mut r = f.record(&s, &d);
        r[field] = json!("wrong");
        f.write(&path, &r);
        assert!(
            s.verify(&d, &f.q, &f.callback, &f.answer).is_none(),
            "accepted {field}"
        );
    }
    f.write(&path, &f.record(&s, &d));
    let mut changed = f.q.clone();
    changed["body"] = json!("changed question");
    assert!(s.verify(&d, &changed, &f.callback, &f.answer).is_none());
    let mut m = serde_json::to_value(&s.manifest).unwrap();
    m["nativeInstanceId"] = json!(uuid::Uuid::new_v4().to_string());
    f.write("manifest.json", &m);
    assert!(s.verify(&d, &f.q, &f.callback, &f.answer).is_none());
}
#[test]
fn unsafe_permissions_symlinks_and_oversize_receipts_fail_closed() {
    let f = Fixture::new();
    fs::set_permissions(
        f.dir.join("manifest.json"),
        fs::Permissions::from_mode(0o644),
    )
    .unwrap();
    assert!(Source::connect(&f.dir, 42).is_err());
    fs::set_permissions(
        f.dir.join("manifest.json"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let s = Source::connect(&f.dir, 42).unwrap();
    let d = s.dispatch(&f.q);
    let name = format!("dispatch-{}.json", d.dispatch_id);
    f.write("original.json", &f.record(&s, &d));
    symlink(f.dir.join("original.json"), f.dir.join(&name)).unwrap();
    assert!(s.verify(&d, &f.q, &f.callback, &f.answer).is_none());
    fs::remove_file(f.dir.join(&name)).unwrap();
    fs::write(f.dir.join(&name), vec![b' '; 1_048_577]).unwrap();
    fs::set_permissions(f.dir.join(&name), fs::Permissions::from_mode(0o600)).unwrap();
    assert!(s.verify(&d, &f.q, &f.callback, &f.answer).is_none());
    fs::set_permissions(&f.dir, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(Source::connect(&f.dir, 42).is_err());
}

#[test]
fn arbitration_and_original_output_are_both_required_before_independent_continuation() {
    let f = Fixture::new();
    let s = Source::connect(&f.dir, 42).unwrap();
    let d = s.dispatch(&f.q);
    let rows = vec![
        json!({"type":"session_meta","payload":{"id":"fixture-session"}}),
        json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"fixture-turn"}}),
    ];
    let lines = |rows: &[Value]| rows.iter().map(|v| format!("{v}\n")).collect::<String>();
    let prefix = lines(&rows);
    let boundary = agentinbox::reply_evidence::DispatchBoundary::capture(&prefix);
    f.write(
        &format!("dispatch-{}.json", d.dispatch_id),
        &f.record(&s, &d),
    );
    assert!(
        s.observe(&d, &f.q, &f.callback, &f.answer, &prefix, &boundary)
            .received
            .is_none()
    );
    let mut rows = rows;
    rows.push(json!({"type":"response_item","payload":{"type":"function_call_output","call_id":"fixture-call","output":codex::response(&f.callback,&f.q,&f.answer).unwrap()["result"].to_string()}}));
    let received = s.observe(&d, &f.q, &f.callback, &f.answer, &lines(&rows), &boundary);
    assert!(received.received.is_some());
    assert!(received.continued.is_none());
    rows.push(
        json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"fixture-turn"}}),
    );
    let continued = s.observe(&d, &f.q, &f.callback, &f.answer, &lines(&rows), &boundary);
    assert!(continued.continued.is_some());
    assert_eq!(
        continued.continued.unwrap()["receivedProofId"],
        received.received.unwrap()["proofId"]
    );
    fs::remove_file(f.dir.join(format!("dispatch-{}.json", d.dispatch_id))).unwrap();
    assert!(
        s.observe(&d, &f.q, &f.callback, &f.answer, &lines(&rows), &boundary)
            .received
            .is_none()
    );
}
