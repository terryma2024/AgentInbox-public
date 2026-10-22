use agentinbox::{
    adapters::{claude, codex},
    store::Store,
};
use serde_json::json;
#[test]
fn one_question_has_one_canonical_answer_encoding() {
    let native = json!({"id":45,"method":"item/tool/requestUserInput","params":{"threadId":"s","turnId":"t","itemId":"i","questions":[{"id":"route","header":"选择","question":"下一步？","options":[{"label":"一"},{"label":"二"}]}]}});
    let q = codex::product_request(&native, "h", "r", 1000, 100).unwrap();
    let id = q["requestId"].as_str().unwrap();
    let store = Store::open(":memory:").unwrap();
    store.create("h", q.clone(), 1000).unwrap();
    let option = q["options"][0]["id"].clone();
    let mut a = json!({"requestId":id,"responseId":"candidate","revision":1,"optionIds":[option],"text":null,"answers":{"route":{"optionIds":[],"text":"另一个答案"}}});
    assert!(
        store.respond("device", a.clone(), 1001).is_err(),
        "conflicting top-level and nested answer must be rejected before dispatch"
    );
    a["answers"] = json!({});
    assert_eq!(
        store.respond("device", a.clone(), 1001).unwrap()["state"],
        "submitting"
    );
    assert_eq!(
        codex::response(&native, &q, &a).unwrap()["result"]["answers"]["route"]["answers"],
        json!(["一"])
    );
}
#[test]
fn multiple_questions_reject_ignored_top_level_choice() {
    let native = json!({"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":"s","prompt_id":"t","tool_use_id":"tool1","tool_input":{"questions":[{"header":"一","question":"第一题","options":[{"label":"甲"}],"multiSelect":false},{"header":"二","question":"第二题","options":[{"label":"乙"}],"multiSelect":false}]}});
    let q = claude::product_request(&native, "h", "r", 1000, 100).unwrap();
    let store = Store::open(":memory:").unwrap();
    store.create("h", q.clone(), 1000).unwrap();
    let mut a = json!({"requestId":q["requestId"],"responseId":"candidate","revision":1,"optionIds":["ignored"],"text":null,"answers":{"q0":{"optionIds":["q0-o0"],"text":null},"q1":{"optionIds":["q1-o0"],"text":null}}});
    assert!(
        store.respond("device", a.clone(), 1001).is_err(),
        "extra unvalidated answer data must be rejected"
    );
    a["optionIds"] = json!([]);
    assert!(store.respond("device", a, 1001).is_ok());
}
