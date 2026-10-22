use serde_json::{Value, json};
use std::collections::BTreeSet;

pub fn is_callback(m: &Value) -> bool {
    matches!(
        m["method"].as_str(),
        Some(
            "item/tool/requestUserInput"
                | "item/commandExecution/requestApproval"
                | "item/fileChange/requestApproval"
        )
    ) && !m["id"].is_null()
}
pub fn same_callback(a: &Value, b: &Value) -> bool {
    is_callback(a)
        && a == b
        && ["threadId", "turnId", "itemId"]
            .iter()
            .all(|k| a["params"][k].as_str().is_some_and(|s| !s.is_empty()))
}
pub fn product_request(
    m: &Value,
    host: &str,
    runtime: &str,
    now: i64,
    ttl: i64,
) -> Result<Value, String> {
    if !same_callback(m, m) {
        return Err("native callback lacks complete identity".into());
    }
    let p = &m["params"];
    if p["questions"].as_array().is_some_and(|qs| {
        qs.iter().any(|q| {
            q["isSecret"] == true
                || q["is_secret"] == true
                || q["question"].as_str().is_some_and(sensitive)
        })
    }) {
        return Err("secret input stays in the native tool".into());
    }
    let approval = m["method"] != "item/tool/requestUserInput";
    let mut questions = Vec::new();
    if !approval {
        let qs = p["questions"].as_array().ok_or("missing questions")?;
        if qs.is_empty() {
            return Err("empty questions".into());
        }
        for (qi, q) in qs.iter().enumerate() {
            let id = q["id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or("missing question id")?;
            let mut options = Vec::new();
            for (oi, o) in q["options"].as_array().into_iter().flatten().enumerate() {
                options.push(json!({"id":format!("q{qi}-o{oi}"),"label":o["label"].as_str().ok_or("missing label")?}));
            }
            questions.push(json!({"id":id,"header":q["header"],"prompt":q["question"],"options":options,"multiSelect":false,"allowText":true}));
        }
    }
    let options = if approval {
        json!([{"id":"allow","label":"批准一次"},{"id":"deny","label":"拒绝"}])
    } else {
        questions[0]["options"].clone()
    };
    let body = if approval {
        if m["method"] == "item/commandExecution/requestApproval" {
            let command = p["command"]
                .as_str()
                .ok_or("approval command is unavailable; keep in native UI")?;
            if sensitive(command) {
                return Err("potential secret in command; keep in native UI".into());
            }
            format!(
                "命令：{command}\n工作目录：{}",
                p["cwd"].as_str().unwrap_or("未知")
            )
        } else {
            return Err("file approval lacks verified full diff; keep in native UI".into());
        }
    } else {
        p["questions"][0]["question"]
            .as_str()
            .unwrap_or("Agent 等待回答")
            .to_string()
    };
    // Export decision content, not the host-only callback or transport identity.
    let mut original = serde_json::Map::new();
    let fields: &[&str] = if approval {
        &[
            "command",
            "commandActions",
            "environmentId",
            "kind",
            "cwd",
            "reason",
            "additionalPermissions",
            "networkApprovalContext",
            "proposedExecpolicyAmendment",
            "proposedNetworkPolicyAmendments",
        ]
    } else {
        &["questions"]
    };
    for field in fields {
        if let Some(value) = p.get(*field) {
            original.insert((*field).into(), value.clone());
        }
    }
    let original = serde_json::to_string_pretty(&original).map_err(|e| e.to_string())?;
    if sensitive(&original) {
        return Err("potential secret in decision context; keep in native UI".into());
    }
    let mut request = json!({"requestId":uuid::Uuid::new_v4().to_string(),"revision":1,"expiresAt":now+ttl,"state":"pending","kind":if approval {"permission"} else if questions.len()==1 {"choice"} else {"questions"},"hostId":host,"engine":"codex","launchSurface":"unknown","runtimeId":runtime,"sessionId":p["threadId"],"turnId":p["turnId"],"nativeRequestId":m["id"].to_string(),"itemId":p["itemId"],"operationSummary":if approval{p["command"].clone()}else{Value::Null},"title":if approval {"Codex 需要审批"} else {"Codex 等待回答"},"body":body,"options":options,"questions":questions,"multiSelect":false,"allowText":!approval,"createdAt":now,"updatedAt":now,"native":{"callback":m}});
    request["projectPath"] = p["cwd"].clone();
    request["decisionContext"] = json!({"taskGoal":null,"blockingReason":if approval {p["reason"].clone()} else {Value::Null},"impactScope":null,"originalContent":original});
    Ok(request)
}
pub fn response(m: &Value, request: &Value, reply: &Value) -> Result<Value, String> {
    if !same_callback(m, &request["native"]["callback"])
        || reply["requestId"] != request["requestId"]
        || reply["revision"] != request["revision"]
    {
        return Err("changed original callback or product binding".into());
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
    if m["method"] != "item/tool/requestUserInput" {
        let selected = reply["optionIds"].as_array().ok_or("missing decision")?;
        if selected.len() != 1 {
            return Err("approval requires one choice".into());
        }
        let decision = match selected[0].as_str() {
            Some("allow") => "accept",
            Some("deny") => "decline",
            _ => return Err("unknown approval option".into()),
        };
        return Ok(json!({"id":m["id"],"result":{"decision":decision}}));
    }
    let qs = request["questions"]
        .as_array()
        .ok_or("missing product questions")?;
    let mut answers = serde_json::Map::new();
    for q in qs {
        let id = q["id"].as_str().ok_or("missing question id")?;
        let source = if request["kind"] != "questions" {
            reply
        } else {
            &reply["answers"][id]
        };
        let values = answer_values(q, source)?;
        answers.insert(id.into(), json!({"answers":values}));
    }
    Ok(json!({"id":m["id"],"result":{"answers":answers}}))
}
pub fn answer_values(q: &Value, reply: &Value) -> Result<Vec<String>, String> {
    let ids = reply["optionIds"].as_array().cloned().unwrap_or_default();
    let mut unique = BTreeSet::new();
    let mut values = Vec::new();
    for id in ids {
        let id = id.as_str().ok_or("invalid option id")?;
        if !unique.insert(id.to_string()) {
            return Err("duplicate choice".into());
        }
        let label = q["options"]
            .as_array()
            .ok_or("no options")?
            .iter()
            .find(|o| o["id"] == id)
            .and_then(|o| o["label"].as_str())
            .ok_or("option outside original question")?;
        values.push(label.to_string());
    }
    if let Some(s) = reply["text"].as_str().filter(|s| !s.trim().is_empty()) {
        if q["allowText"] != true || !values.is_empty() {
            return Err("text not allowed or mixed with choice".into());
        }
        values.push(s.to_string());
    }
    if values.is_empty() || (q["multiSelect"] != true && values.len() != 1) {
        return Err("invalid answer cardinality".into());
    }
    Ok(values)
}

pub fn inspect(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    use std::os::unix::net::UnixStream;
    use tungstenite::Message;
    let socket = args.first().ok_or("inspect-codex SOCKET SCOPE")?;
    let scope = args.get(1).ok_or("scope required")?;
    let stream = UnixStream::connect(socket)?;
    println!(
        "{}",
        json!({"transportPeerPid":crate::host::peer_pid(&stream)?})
    );
    stream.set_read_timeout(Some(std::time::Duration::from_secs(8)))?;
    let (mut ws, _) = tungstenite::client("ws://codex-app-server/rpc", stream)?;
    ws.send(Message::Text(json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"agentinbox_diagnostics","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}).to_string()))?;
    let mut received = 0;
    loop {
        if let Message::Text(text) = ws.read()? {
            let m: Value = serde_json::from_str(&text)?;
            if m["id"] == 1 && m.get("result").is_some() {
                ws.send(Message::Text(json!({"method":"initialized"}).to_string()))?;
                ws.send(Message::Text(
                    json!({"id":2,"method":"thread/loaded/list","params":{"limit":100}})
                        .to_string(),
                ))?;
                ws.send(Message::Text(json!({"id":3,"method":"thread/list","params":{"cwd":scope,"limit":100,"useStateDbOnly":true}}).to_string()))?;
            }
            if m["id"] == 2 {
                println!(
                    "{}",
                    json!({"loadedResult":m.get("result"),"error":m.get("error")})
                );
                received += 1;
            }
            if m["id"] == 3 {
                for t in m["result"]["data"].as_array().into_iter().flatten() {
                    println!(
                        "{}",
                        json!({"threadId":t["id"],"source":t["source"],"originator":t["originator"],"status":t["status"],"rolloutPath":t["path"]})
                    );
                }
                received += 1;
            }
            if received == 2 {
                ws.close(None)?;
                return Ok(());
            }
        }
    }
}

pub fn sensitive(s: &str) -> bool {
    let s = s.to_ascii_lowercase();
    [
        "authorization:",
        "bearer ",
        "api_key",
        "apikey",
        "access_token",
        "refresh_token",
        "password=",
        "secret=",
        "private key",
        "aws_secret",
        "密码",
        "私钥",
        "访问令牌",
        "验证码",
    ]
    .iter()
    .any(|k| s.contains(k))
}

/// Cleans up only an explicitly recorded question-only fixture, never a user operation.
pub fn cancel_fixture(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    use std::os::unix::net::UnixStream;
    use tungstenite::Message;
    let socket = args
        .first()
        .ok_or("cancel-fixture SOCKET SCOPE BINDING_JSON")?;
    let scope = args.get(1).ok_or("scope required")?;
    let binding: Value =
        serde_json::from_slice(&std::fs::read(args.get(2).ok_or("binding required")?)?)?;
    let original = &binding["native"]["callback"];
    if original["method"] != "item/tool/requestUserInput"
        || original["params"]["questions"][0]["question"] != "AGENTINBOX_CHOOSE_ROUTE"
    {
        return Err("not an owned question-only fixture".into());
    }
    let thread = original["params"]["threadId"]
        .as_str()
        .ok_or("thread missing")?;
    let turn = original["params"]["turnId"]
        .as_str()
        .ok_or("turn missing")?;
    let stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(8)))?;
    let peer = crate::host::peer_pid(&stream)?;
    crate::host::generation(peer).map_err(std::io::Error::other)?;
    let (mut ws, _) = tungstenite::client("ws://codex-app-server/rpc", stream)?;
    ws.send(Message::Text(json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"agentinbox_fixture_cleanup","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}).to_string()))?;
    let mut loaded = false;
    let mut interrupted = false;
    loop {
        if let Message::Text(text) = ws.read()? {
            let m: Value = serde_json::from_str(&text)?;
            if m.get("error").is_some() {
                return Err("cleanup RPC rejected; no retry".into());
            }
            if m["id"] == 1 && m.get("result").is_some() {
                ws.send(Message::Text(json!({"method":"initialized"}).to_string()))?;
                ws.send(Message::Text(
                    json!({"id":2,"method":"thread/loaded/list","params":{"limit":100}})
                        .to_string(),
                ))?;
            }
            if m["id"] == 2 {
                loaded = m["result"]["data"]
                    .as_array()
                    .is_some_and(|a| a.iter().any(|id| id == thread));
                if !loaded {
                    return Err("owned fixture is not loaded".into());
                }
                ws.send(Message::Text(json!({"id":3,"method":"thread/list","params":{"cwd":scope,"limit":100,"useStateDbOnly":true}}).to_string()))?;
            }
            if m["id"] == 3 {
                let matches: Vec<_> = m["result"]["data"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|t| {
                        t["id"] == thread
                            && t["cwd"] == scope.as_str()
                            && t["status"]["activeFlags"]
                                .as_array()
                                .is_some_and(|a| a.iter().any(|f| f == "waitingOnUserInput"))
                    })
                    .collect();
                if matches.len() != 1 {
                    return Err("owned fixture no longer uniquely waiting".into());
                }
                ws.send(Message::Text(json!({"id":4,"method":"thread/resume","params":{"threadId":thread,"excludeTurns":true}}).to_string()))?;
            }
            if loaded && is_callback(&m) && m["params"]["threadId"] == thread {
                if interrupted || !same_callback(&m, original) {
                    return Err("original callback changed; no cancellation".into());
                }
                ws.send(Message::Text(json!({"id":5,"method":"turn/interrupt","params":{"threadId":thread,"turnId":turn}}).to_string()))?;
                interrupted = true;
            }
            if interrupted
                && m["method"] == "turn/completed"
                && m["params"]["threadId"] == thread
                && m["params"]["turn"]["id"] == turn
            {
                if m["params"]["turn"]["status"] != "interrupted" {
                    return Err("original turn not confirmed interrupted".into());
                }
                println!(
                    "{}",
                    json!({"ownedFixtureInterrupted":true,"threadId":thread,"turnId":turn,"answerDispatched":false})
                );
                ws.close(None)?;
                return Ok(());
            }
        }
    }
}
