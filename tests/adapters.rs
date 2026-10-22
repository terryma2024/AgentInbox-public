use agentinbox::adapters::{claude, codex};
use serde_json::{Value, json};
fn callback() -> Value {
    json!({"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"t1","turnId":"turn1","itemId":"item1","questions":[{"id":"q1","header":"选择","question":"问题","options":[{"label":"Alpha"},{"label":"Beta"}]}]}})
}
fn reply(r: &Value) -> Value {
    json!({"responseId":"r1","requestId":r["requestId"],"revision":1,"optionIds":["q0-o1"]})
}
#[test]
fn native_option_mapping() {
    let m = callback();
    let r = codex::product_request(&m, "host", "runtime", 100, 60).unwrap();
    assert_eq!(
        codex::response(&m, &r, &reply(&r)).unwrap()["result"]["answers"]["q1"]["answers"],
        json!(["Beta"])
    );
}
#[test]
fn old_native_request_rejected() {
    let m = callback();
    let r = codex::product_request(&m, "host", "runtime", 100, 60).unwrap();
    for key in ["threadId", "turnId", "itemId"] {
        let mut changed = m.clone();
        changed["params"][key] = json!("new");
        assert!(codex::response(&changed, &r, &reply(&r)).is_err());
    }
    let mut changed = m.clone();
    changed["id"] = json!(43);
    assert!(codex::response(&changed, &r, &reply(&r)).is_err());
}
#[test]
fn changed_original_question_rejected() {
    let m = callback();
    let r = codex::product_request(&m, "host", "runtime", 100, 60).unwrap();
    let mut changed = m.clone();
    changed["params"]["questions"][0]["options"][1]["label"] = json!("changed");
    assert!(codex::response(&changed, &r, &reply(&r)).is_err());
}
#[test]
fn missing_native_identity_rejected() {
    for key in ["threadId", "turnId", "itemId"] {
        let mut m = callback();
        m["params"].as_object_mut().unwrap().remove(key);
        assert!(codex::product_request(&m, "h", "r", 100, 60).is_err());
    }
}
#[test]
fn chinese_text() {
    let m = callback();
    let r = codex::product_request(&m, "h", "r", 100, 60).unwrap();
    let ans = json!({"requestId":r["requestId"],"revision":1,"optionIds":[],"text":"中文答复"});
    assert_eq!(
        codex::response(&m, &r, &ans).unwrap()["result"]["answers"]["q1"]["answers"],
        json!(["中文答复"])
    );
}
#[test]
fn foreign_option_rejected() {
    let m = callback();
    let r = codex::product_request(&m, "h", "r", 100, 60).unwrap();
    let mut a = reply(&r);
    a["optionIds"] = json!(["foreign"]);
    assert!(codex::response(&m, &r, &a).is_err());
}
#[test]
fn mixed_text_choice_rejected() {
    let m = callback();
    let r = codex::product_request(&m, "h", "r", 100, 60).unwrap();
    let mut a = reply(&r);
    a["text"] = json!("also text");
    assert!(codex::response(&m, &r, &a).is_err());
}
#[test]
fn wrong_revision_rejected() {
    let m = callback();
    let r = codex::product_request(&m, "h", "r", 100, 60).unwrap();
    let mut a = reply(&r);
    a["revision"] = json!(2);
    assert!(codex::response(&m, &r, &a).is_err());
}
#[test]
fn explicit_approval_only() {
    let m = json!({"id":42,"method":"item/commandExecution/requestApproval","params":{"threadId":"t","turnId":"turn","itemId":"i","command":"echo fixture"}});
    let r = codex::product_request(&m, "h", "r", 100, 60).unwrap();
    let a = json!({"requestId":r["requestId"],"revision":1,"optionIds":["deny"]});
    assert_eq!(
        codex::response(&m, &r, &a).unwrap()["result"]["decision"],
        "decline"
    );
}
fn hook() -> Value {
    json!({"session_id":"s1","tool_use_id":"tool1","prompt_id":"p1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"原问题","header":"选择","multiSelect":true,"options":[{"label":"A"},{"label":"B"}]}]}})
}
#[test]
fn claude_multiselect_keeps_input() {
    let e = hook();
    let r = claude::product_request(&e, "h", "rt", 100, 60).unwrap();
    let a = json!({"requestId":r["requestId"],"revision":1,"optionIds":["q0-o0","q0-o1"]});
    let out = claude::output(&e, &r, &a).unwrap();
    assert_eq!(
        out["hookSpecificOutput"]["updatedInput"]["answers"]["原问题"],
        "A, B"
    );
    assert_eq!(
        out["hookSpecificOutput"]["updatedInput"]["questions"],
        e["tool_input"]["questions"]
    );
}
#[test]
fn claude_absent_prompt_not_fabricated() {
    let mut e = hook();
    e.as_object_mut().unwrap().remove("prompt_id");
    let r = claude::product_request(&e, "h", "rt", 100, 60).unwrap();
    assert!(r["turnId"].is_null());
}
#[test]
fn claude_missing_toolid_refused() {
    let mut e = hook();
    e.as_object_mut().unwrap().remove("tool_use_id");
    assert!(claude::product_request(&e, "h", "rt", 100, 60).is_err());
}
#[test]
fn claude_changed_native_event_refused() {
    let e = hook();
    let r = claude::product_request(&e, "h", "rt", 100, 60).unwrap();
    let mut changed = e.clone();
    changed["tool_use_id"] = json!("next");
    assert!(claude::output(&changed, &r, &reply(&r)).is_err());
}
#[test]
fn single_nested_encoding_is_rejected() {
    let m = callback();
    let r = codex::product_request(&m, "h", "r", 100, 60).unwrap();
    let mut a = reply(&r);
    a["answers"] = json!({"q1":{"optionIds":["q0-o0"]}});
    assert!(codex::response(&m, &r, &a).is_err());
    let e = hook();
    let r = claude::product_request(&e, "h", "rt", 100, 60).unwrap();
    let mut a = reply(&r);
    a["answers"] = json!({"q0":{"optionIds":["q0-o0"]}});
    assert!(claude::output(&e, &r, &a).is_err());
}
#[test]
fn null_options_allows_only_text() {
    let mut m = callback();
    m["params"]["questions"][0]["options"] = Value::Null;
    let r = codex::product_request(&m, "h", "rt", 100, 60).unwrap();
    let a = json!({"requestId":r["requestId"],"revision":1,"optionIds":[],"text":"中文"});
    assert!(codex::response(&m, &r, &a).is_ok());
}
#[test]
fn secret_questions_remain_native() {
    let mut m = callback();
    m["params"]["questions"][0]["isSecret"] = json!(true);
    assert!(codex::product_request(&m, "h", "rt", 100, 60).is_err());
}
#[test]
fn native_file_permission_without_diff_refused() {
    let m = json!({"id":1,"method":"item/fileChange/requestApproval","params":{"threadId":"t","turnId":"turn","itemId":"i"}});
    assert!(codex::product_request(&m, "h", "rt", 100, 60).is_err());
}
#[test]
fn claude_permission_shows_exact_command() {
    let e = json!({"session_id":"s","tool_use_id":"i","hook_event_name":"PermissionRequest","tool_name":"Bash","cwd":"/fixture","tool_input":{"command":"printf FIRST"}});
    let a = claude::product_request(&e, "h", "rt", 100, 60).unwrap();
    let mut changed = e.clone();
    changed["tool_input"]["command"] = json!("printf SECOND");
    let b = claude::product_request(&changed, "h", "rt", 100, 60).unwrap();
    assert_ne!(a["body"], b["body"]);
    assert!(a["body"].as_str().unwrap().contains("printf FIRST"));
}
