use agentinbox::{
    adapters::{claude, codex},
    reply_evidence::{DispatchBoundary, observe},
};
use serde_json::{Value, json};
fn codex_fixture() -> (Value, Value, Value) {
    let c = json!({"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"s","turnId":"t","itemId":"call","questions":[{"id":"q","question":"Pick","options":[{"label":"Alpha"},{"label":"Beta"}]}]}});
    let q = codex::product_request(&c, "h", "r", 100, 600).unwrap();
    let a = json!({"requestId":q["requestId"],"responseId":"answer","revision":1,"optionIds":["q0-o1"]});
    (q, c, a)
}
fn codex_rows(answer: &str) -> Vec<Value> {
    vec![
        json!({"type":"session_meta","payload":{"id":"s"}}),
        json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}),
        json!({"type":"response_item","payload":{"type":"function_call_output","call_id":"call","output":json!({"answers":{"q":{"answers":[answer]}}}).to_string()}}),
    ]
}
fn lines(rows: &[Value]) -> String {
    rows.iter().map(|r| format!("{r}\n")).collect()
}
#[test]
fn exact_output_and_original_continuation_are_separate() {
    let (q, c, a) = codex_fixture();
    let mut rows = codex_rows("Beta");
    let b = DispatchBoundary::capture(&lines(&rows[..2]));
    let result = observe(&q, &c, &a, &lines(&rows), &b);
    assert!(result.received.is_some());
    assert!(result.continued.is_none());
    rows.push(json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"t"}}));
    assert!(observe(&q, &c, &a, &lines(&rows), &b).continued.is_some());
}
#[test]
fn wrong_binding_answer_and_duplicate_outputs_are_not_proofs() {
    let (q, c, a) = codex_fixture();
    for mode in 0..5 {
        let mut rows = codex_rows("Beta");
        match mode {
            0 => rows[0]["payload"]["id"] = json!("other"),
            1 => rows[1]["payload"]["turn_id"] = json!("other"),
            2 => rows[2]["payload"]["call_id"] = json!("other"),
            3 => rows = codex_rows("Alpha"),
            _ => rows.push(rows[2].clone()),
        };
        let b = DispatchBoundary::capture(&lines(&rows[..2]));
        assert!(
            observe(&q, &c, &a, &lines(&rows), &b).received.is_none(),
            "bad case {mode}"
        );
    }
}
#[test]
fn pre_dispatch_result_and_rewritten_prefix_cannot_be_adopted() {
    let (q, c, a) = codex_fixture();
    let rows = codex_rows("Beta");
    let old = lines(&rows);
    let b = DispatchBoundary::capture(&old);
    assert!(observe(&q, &c, &a, &old, &b).received.is_none());
    let mut changed = rows;
    changed[0]["payload"]["id"] = json!("rewritten");
    assert!(observe(&q, &c, &a, &lines(&changed), &b).received.is_none());
}
#[test]
fn next_turn_or_pre_result_text_cannot_prove_continuation() {
    let (q, c, a) = codex_fixture();
    let mut rows = codex_rows("Beta");
    let b = DispatchBoundary::capture(&lines(&rows[..2]));
    rows.push(json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"other"}}));
    rows.push(json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"other"}}));
    assert!(observe(&q, &c, &a, &lines(&rows), &b).continued.is_none());
}
#[test]
fn claude_continuation_requires_tool_result_parent_chain() {
    let c = json!({"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":"s","prompt_id":"p","tool_use_id":"tool","tool_input":{"questions":[{"question":"Pick","options":[{"label":"Alpha"},{"label":"Beta"}]}]}});
    let q = claude::product_request(&c, "h", "r", 100, 600).unwrap();
    let a = json!({"requestId":q["requestId"],"responseId":"answer","revision":1,"optionIds":["q0-o1"]});
    let row = json!({"uuid":"result","sessionId":"s","promptId":"p","toolUseResult":{"questions":c["tool_input"]["questions"],"answers":{"Pick":"Beta"}},"message":{"content":[{"type":"tool_result","tool_use_id":"tool","is_error":false}]}});
    let mut rows = vec![row];
    let b = DispatchBoundary::capture("");
    assert!(observe(&q, &c, &a, &lines(&rows), &b).received.is_some());
    rows.push(json!({"uuid":"assistant","parentUuid":"wrong","type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"Continue"}]}}));
    assert!(observe(&q, &c, &a, &lines(&rows), &b).continued.is_none());
    rows[1]["parentUuid"] = json!("result");
    assert!(observe(&q, &c, &a, &lines(&rows), &b).continued.is_some());
}
