use super::codex::answer_values;
use serde_json::{Value, json};

/// Retains real hook identity; prompt_id is absent in some engines and is never invented.
pub fn product_request(
    event: &Value,
    host: &str,
    runtime: &str,
    now: i64,
    ttl: i64,
) -> Result<Value, String> {
    let session = event["session_id"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("missing session_id")?;
    let toolid = event["tool_use_id"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("missing native tool_use_id; correlate a unique PreToolUse first")?;
    let approval = event["hook_event_name"] == "PermissionRequest";
    if !approval
        && !(event["hook_event_name"] == "PreToolUse" && event["tool_name"] == "AskUserQuestion")
    {
        return Err("unsupported hook".into());
    }
    if super::codex::sensitive(&event["tool_input"].to_string()) {
        return Err("potential secret stays in native tool".into());
    }
    let approval_body = if approval {
        format!(
            "工具：{}\n工作目录：{}\n参数：{}",
            event["tool_name"].as_str().ok_or("missing tool")?,
            event["cwd"].as_str().unwrap_or("见原任务"),
            serde_json::to_string_pretty(&event["tool_input"]).map_err(|e| e.to_string())?
        )
    } else {
        String::new()
    };
    let mut questions = Vec::new();
    if !approval {
        for (qi, q) in event["tool_input"]["questions"]
            .as_array()
            .ok_or("missing questions")?
            .iter()
            .enumerate()
        {
            let options: Vec<_> = q["options"]
                .as_array()
                .ok_or("missing options")?
                .iter()
                .enumerate()
                .map(|(oi, o)| json!({"id":format!("q{qi}-o{oi}"),"label":o["label"]}))
                .collect();
            questions.push(json!({"id":format!("q{qi}"),"nativeQuestion":q["question"].as_str().ok_or("missing native question")?,"header":q["header"],"prompt":q["question"],"options":options,"allowText":true,"multiSelect":q["multiSelect"]==true}));
        }
        if questions.is_empty() {
            return Err("empty questions".into());
        }
    }
    let opts = if approval {
        json!([{"id":"allow","label":"批准一次"},{"id":"deny","label":"拒绝"}])
    } else {
        questions[0]["options"].clone()
    };
    Ok(
        json!({"requestId":uuid::Uuid::new_v4().to_string(),"revision":1,"expiresAt":now+ttl,"state":"pending","kind":if approval{"permission"}else if questions.len()==1{"choice"}else{"questions"},"hostId":host,"engine":"claude","launchSurface":"unknown","projectPath":event["cwd"],"sessionLabel":null,"runtimeId":runtime,"sessionId":session,"turnId":event.get("prompt_id"),"nativeRequestId":toolid,"itemId":toolid,"operationSummary":if approval{json!(approval_body)}else{Value::Null},"title":if approval{"Claude 需要审批"}else{"Claude 等待回答"},"body":if approval{json!(approval_body)}else{questions[0]["prompt"].clone()},"options":opts,"questions":questions,"multiSelect":event["tool_input"]["questions"][0]["multiSelect"]==true,"allowText":!approval,"createdAt":now,"updatedAt":now,"native":{"event":event}}),
    )
}
pub fn output(event: &Value, request: &Value, reply: &Value) -> Result<Value, String> {
    if event != &request["native"]["event"]
        || reply["requestId"] != request["requestId"]
        || reply["revision"] != request["revision"]
    {
        return Err("changed native or product binding".into());
    }
    if request["kind"] != "questions" && reply["answers"].as_object().is_some_and(|a| !a.is_empty())
    {
        return Err("single request cannot contain nested answers".into());
    }
    if request["kind"] == "questions"
        && (reply["optionIds"].as_array().is_some_and(|a| !a.is_empty())
            || reply["text"].as_str().is_some_and(|s| !s.is_empty()))
    {
        return Err("multi-question cannot contain top-level answer".into());
    }
    if event["hook_event_name"] == "PermissionRequest" {
        let ids = reply["optionIds"].as_array().ok_or("missing choice")?;
        if ids.len() != 1 {
            return Err("requires one choice".into());
        }
        let behavior = match ids[0].as_str() {
            Some("allow") => "allow",
            Some("deny") => "deny",
            _ => return Err("invalid approval choice".into()),
        };
        return Ok(
            json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":behavior}}}),
        );
    }
    let mut input = event["tool_input"].clone();
    let qs = request["questions"].as_array().ok_or("missing questions")?;
    let mut answers = serde_json::Map::new();
    for q in qs {
        let id = q["id"].as_str().ok_or("no question id")?;
        let source = if request["kind"] != "questions" {
            reply
        } else {
            &reply["answers"][id]
        };
        answers.insert(
            q["nativeQuestion"]
                .as_str()
                .ok_or("missing original question")?
                .into(),
            json!(answer_values(q, source)?.join(", ")),
        );
    }
    input
        .as_object_mut()
        .ok_or("invalid input")?
        .insert("answers".into(), Value::Object(answers));
    Ok(
        json!({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":input}}),
    )
}
