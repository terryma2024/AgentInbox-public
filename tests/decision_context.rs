use agentinbox::{
    adapters::{claude, codex},
    reply_progress::binding_digest,
    store::Store,
};
use serde_json::{Value, json};

fn approval() -> Value {
    json!({"id":42,"method":"item/commandExecution/requestApproval","params":{
        "threadId":"fixture-thread","turnId":"fixture-turn","itemId":"fixture-item",
        "cwd":"/srv/example-project","command":"printf 'first\\nlast'",
        "reason":"需要在沙箱外运行集成检查"}})
}

#[test]
fn codex_context_keeps_exact_command_reason_and_directory_without_guessing_scope() {
    let mut m = approval();
    let command = format!(
        "{}\n末尾关键参数 --target example.invalid",
        "echo fixture\n".repeat(800)
    );
    m["params"]["command"] = json!(command);
    m["params"]["environmentId"] = json!("fixture-environment");
    m["params"]["kind"] = json!("command");
    m["params"]["commandActions"] = json!([{"type":"unknown","command":"echo fixture"}]);
    let q = codex::product_request(&m, "fixture-host", "fixture-runtime", 100, 60).unwrap();
    assert_eq!(q["projectPath"], "/srv/example-project");
    assert_eq!(
        q["decisionContext"]["blockingReason"],
        "需要在沙箱外运行集成检查"
    );
    assert!(q["decisionContext"]["taskGoal"].is_null());
    assert!(q["decisionContext"]["impactScope"].is_null());
    let original: Value =
        serde_json::from_str(q["decisionContext"]["originalContent"].as_str().unwrap()).unwrap();
    assert_eq!(original["command"], command);
    assert_eq!(original["environmentId"], "fixture-environment");
    assert_eq!(original["kind"], "command");
    assert_eq!(original["commandActions"], m["params"]["commandActions"]);
    assert!(original.get("threadId").is_none());
}

#[test]
fn every_question_and_option_description_survives_device_view() {
    let mut m = approval();
    m["method"] = json!("item/tool/requestUserInput");
    m["params"]["questions"] = json!([
        {"id":"fixture-q1","header":"环境","question":"第一题","options":[{"label":"测试","description":"仅运行本地测试；不部署"}]},
        {"id":"fixture-q2","question":"第二题末尾","options":[]}
    ]);
    let q = codex::product_request(&m, "fixture-host", "fixture-runtime", 100, 60).unwrap();
    let store = Store::open(":memory:").unwrap();
    store.create("fixture-host", q.clone(), 100).unwrap();
    let device = store.get(q["requestId"].as_str().unwrap(), false).unwrap();
    assert!(device.get("native").is_none());
    let original: Value = serde_json::from_str(
        device["decisionContext"]["originalContent"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(original["questions"], m["params"]["questions"]);
}

#[test]
fn claude_permission_keeps_full_tool_input_and_missing_context_unknown() {
    let input =
        json!({"command":"echo fixture\necho last","description":"验证示例","timeout":12345});
    let event = json!({"session_id":"fixture-session","tool_use_id":"fixture-tool","hook_event_name":"PermissionRequest","tool_name":"Bash","cwd":"/srv/example-project","tool_input":input});
    let q = claude::product_request(&event, "fixture-host", "fixture-runtime", 100, 60).unwrap();
    let original: Value =
        serde_json::from_str(q["decisionContext"]["originalContent"].as_str().unwrap()).unwrap();
    assert_eq!(original["tool_input"], input);
    assert_eq!(original["tool_name"], "Bash");
    assert!(q["decisionContext"]["taskGoal"].is_null());
    assert!(q["decisionContext"]["blockingReason"].is_null());
    assert!(q["decisionContext"]["impactScope"].is_null());
}

#[test]
fn decision_context_is_part_of_answer_binding() {
    let mut q =
        codex::product_request(&approval(), "fixture-host", "fixture-runtime", 100, 60).unwrap();
    q["decisionContext"] = json!({"taskGoal":"运行示例检查","blockingReason":null,"impactScope":null,"originalContent":"echo fixture"});
    let original_digest = binding_digest(&q);
    for (field, value) in [
        ("taskGoal", "另一个任务"),
        ("blockingReason", "另一个原因"),
        ("impactScope", "远程部署"),
        ("originalContent", "echo changed"),
    ] {
        let mut changed = q.clone();
        changed["decisionContext"][field] = json!(value);
        assert_ne!(
            original_digest,
            binding_digest(&changed),
            "unbound field: {field}"
        );
    }
    for field in ["projectPath", "sessionLabel"] {
        let mut changed = q.clone();
        changed[field] = json!("changed-fixture");
        assert_ne!(original_digest, binding_digest(&changed));
    }
}

#[test]
fn stale_context_digest_cannot_submit_to_another_context() {
    let q =
        codex::product_request(&approval(), "fixture-host", "fixture-runtime", 100, 60).unwrap();
    let mut changed = q.clone();
    changed["decisionContext"]["impactScope"] = json!("示例部署目录");
    let store = Store::open(":memory:").unwrap();
    store.create("fixture-host", changed.clone(), 100).unwrap();
    let mut answer = json!({"requestId":q["requestId"],"revision":1,"responseId":"fixture-answer","optionIds":["allow"],"bindingDigest":binding_digest(&q)});
    assert_eq!(
        store
            .respond("fixture-device", answer.clone(), 101)
            .unwrap_err()
            .status,
        409
    );
    assert_eq!(
        store.get(q["requestId"].as_str().unwrap(), false).unwrap()["state"],
        "pending"
    );
    answer["bindingDigest"] = json!(binding_digest(&changed));
    assert_eq!(
        store.respond("fixture-device", answer, 102).unwrap()["state"],
        "submitting"
    );
}

#[test]
fn legacy_digest_stays_compatible_with_in_flight_replies() {
    let q = json!({"requestId":"fixture-legacy","revision":1,"hostId":"fixture-host","engine":"codex","runtimeId":"fixture-runtime","sessionId":"fixture-session","turnId":"fixture-turn","nativeRequestId":"fixture-native","itemId":"fixture-item","expiresAt":160,"kind":"choice","title":"Fixture","body":"Question","options":[{"id":"a","label":"A"}],"questions":null,"multiSelect":false,"allowText":true,"operationSummary":null,"projectPath":"/srv/example-project","sessionLabel":"Fixture"});
    // Frozen v1 fingerprint before decisionContext existed; display fields were unbound.
    assert_eq!(
        binding_digest(&q),
        "65e44f9197abce981ef55b68deb85331bbdbac28edddfaf76197bf71c9cd787e"
    );
}

#[test]
fn sensitive_context_is_kept_in_native_ui_instead_of_exported() {
    let mut m = approval();
    m["params"]["reason"] = json!("authorization: PUBLIC_FIXTURE_NOT_A_CREDENTIAL");
    assert!(codex::product_request(&m, "fixture-host", "fixture-runtime", 100, 60).is_err());
    m["params"]["reason"] = Value::Null;
    m["method"] = json!("item/tool/requestUserInput");
    m["params"]["questions"] = json!([{"id":"fixture-q","question":"选择","options":[{"label":"A","description":"authorization: PUBLIC_FIXTURE_NOT_A_CREDENTIAL"}]}]);
    assert!(codex::product_request(&m, "fixture-host", "fixture-runtime", 100, 60).is_err());
}
