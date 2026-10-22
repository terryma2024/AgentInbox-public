//! Read-only observations of the original execution chain. Content match alone does
//! not attribute a same-valued local/remote race to the remote responder.
use crate::adapters::{claude, codex};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchBoundary {
    pub bytes: usize,
    pub digest: String,
}
impl DispatchBoundary {
    pub fn capture(prefix: &str) -> Self {
        Self {
            bytes: prefix.len(),
            digest: hash(prefix.as_bytes()),
        }
    }
    fn matches(&self, text: &str) -> bool {
        text.as_bytes()
            .get(..self.bytes)
            .is_some_and(|p| hash(p) == self.digest)
    }
}
#[derive(Default, Debug)]
pub struct Observation {
    pub received: Option<Value>,
    pub continued: Option<Value>,
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn proof(kind: &str, line: &str, position: usize) -> Value {
    let digest = hash(line.as_bytes());
    json!({"proofId":format!("proof-{position}-{digest}"),"kind":kind,"sourceDigest":digest,"position":position})
}
pub fn observe(
    q: &Value,
    callback: &Value,
    answer: &Value,
    text: &str,
    boundary: &DispatchBoundary,
) -> Observation {
    if !boundary.matches(text) {
        return Observation::default();
    }
    let Ok(expected) = (if q["engine"] == "codex" {
        codex::response(callback, q, answer)
    } else {
        claude::output(callback, q, answer)
    }) else {
        return Observation::default();
    };
    let mut received = None;
    let mut continued = None;
    let mut matches = 0;
    let mut offset = 0;
    let mut session_ok = false;
    let mut turn_ok = false;
    let mut result_uuid = None;
    let mut chain = std::collections::HashSet::new();
    for (index, line) in text.lines().enumerate() {
        let start = offset;
        offset += line.len() + 1;
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            return Observation::default();
        };
        let after_dispatch = start >= boundary.bytes;
        if q["engine"] == "codex" {
            if callback["method"] != "item/tool/requestUserInput" {
                return Observation::default();
            }
            if v["type"] == "session_meta" {
                session_ok = v["payload"]["id"] == q["sessionId"];
            }
            if v["type"] == "event_msg" && v["payload"]["type"] == "task_started" {
                turn_ok = v["payload"]["turn_id"] == q["turnId"];
            }
            if !session_ok || !turn_ok {
                continue;
            }
            if v["type"] == "response_item"
                && v["payload"]["type"] == "function_call_output"
                && v["payload"]["call_id"] == q["itemId"]
            {
                matches += 1;
                let actual = v["payload"]["output"]
                    .as_str()
                    .and_then(|s| serde_json::from_str::<Value>(s).ok());
                if after_dispatch && actual.as_ref() == Some(&expected["result"]) {
                    received = Some(proof("codex.function_call_output", line, index + 1));
                } else {
                    return Observation::default();
                }
            } else if received.is_some() && continued.is_none() && after_dispatch {
                let completion = v["type"] == "event_msg"
                    && v["payload"]["type"] == "task_complete"
                    && v["payload"]["turn_id"] == q["turnId"];
                let progress = v["type"] == "response_item"
                    && v["payload"]["type"] == "message"
                    && v["payload"]["role"] == "assistant";
                if completion || progress {
                    continued = Some(proof(
                        if completion {
                            "codex.turn_completed"
                        } else {
                            "codex.next_item"
                        },
                        line,
                        index + 1,
                    ));
                }
            }
        } else if q["engine"] == "claude" {
            if callback["tool_name"] != "AskUserQuestion" {
                return Observation::default();
            }
            let session = v["sessionId"] == callback["session_id"]
                || v["session_id"] == callback["session_id"];
            if !session {
                continue;
            }
            let blocks = v["message"]["content"].as_array();
            let original_result = blocks.is_some_and(|bs| {
                bs.iter().any(|b| {
                    b["type"] == "tool_result" && b["tool_use_id"] == callback["tool_use_id"]
                })
            });
            if original_result {
                matches += 1;
                let prompt =
                    callback["prompt_id"].is_null() || v["promptId"] == callback["prompt_id"];
                let correct = blocks.is_some_and(|bs| {
                    bs.iter().any(|b| {
                        b["type"] == "tool_result"
                            && b["tool_use_id"] == callback["tool_use_id"]
                            && b["is_error"] != true
                    })
                });
                if after_dispatch
                    && prompt
                    && correct
                    && v["toolUseResult"]["questions"]
                        == expected["hookSpecificOutput"]["updatedInput"]["questions"]
                    && v["toolUseResult"]["answers"]
                        == expected["hookSpecificOutput"]["updatedInput"]["answers"]
                {
                    received = Some(proof("claude.tool_result", line, index + 1));
                    result_uuid = v["uuid"].as_str().map(str::to_owned);
                    if let Some(id) = &result_uuid {
                        chain.insert(id.clone());
                    }
                } else {
                    return Observation::default();
                }
            } else if received.is_some()
                && continued.is_none()
                && after_dispatch
                && result_uuid.is_some()
                && v["parentUuid"]
                    .as_str()
                    .is_some_and(|id| chain.contains(id))
            {
                if let Some(id) = v["uuid"].as_str() {
                    chain.insert(id.into());
                }
                if v["type"] == "assistant"
                    && blocks.is_some_and(|bs| {
                        bs.iter().any(|b| {
                            ["text", "tool_use", "thinking"]
                                .contains(&b["type"].as_str().unwrap_or(""))
                        })
                    })
                {
                    continued = Some(proof("claude.assistant", line, index + 1));
                }
            }
        }
    }
    if matches != 1 {
        return Observation::default();
    }
    if let Some(p) = continued.as_mut() {
        p["receivedProofId"] = received.as_ref().unwrap()["proofId"].clone();
    }
    Observation {
        received,
        continued,
    }
}
