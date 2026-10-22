//! Durable facts about an answer; legacy lifecycle state is deliberately separate.
use crate::model::*;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub const IDENTITY: &[&str] = &[
    "requestId",
    "revision",
    "hostId",
    "engine",
    "runtimeId",
    "sessionId",
    "turnId",
    "nativeRequestId",
    "itemId",
];

pub fn binding_digest(q: &Value) -> String {
    let mut fields = serde_json::Map::new();
    for key in IDENTITY.iter().copied().chain([
        "expiresAt",
        "kind",
        "title",
        "body",
        "options",
        "questions",
        "multiSelect",
        "allowText",
        "operationSummary",
    ]) {
        fields.insert(key.into(), q[key].clone());
    }
    // serde_json without preserve_order uses recursively sorted map keys.
    format!(
        "{:x}",
        Sha256::digest(Value::Object(fields).to_string().as_bytes())
    )
}
pub fn install(db: &Connection) -> ApiResult<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS reply_progress(request TEXT PRIMARY KEY,response TEXT NOT NULL UNIQUE,json TEXT NOT NULL,FOREIGN KEY(request) REFERENCES requests(id),FOREIGN KEY(response) REFERENCES responses(id));")?;
    Ok(())
}
fn empty(q: &Value, response: &str, at: Option<i64>) -> Value {
    json!({"schemaVersion":1,"requestId":q["requestId"],"responseId":response,"bindingDigest":binding_digest(q),"submitted":{"at":at},"received":null,"continued":null,"continuationObservation":"unobserved"})
}
pub fn record_submission(tx: &Transaction<'_>, q: &Value, a: &Value, time: i64) -> ApiResult<()> {
    let p = empty(q, string(a, "responseId")?, Some(time));
    tx.execute(
        "INSERT INTO reply_progress VALUES(?1,?2,?3)",
        params![
            string(q, "requestId")?,
            string(a, "responseId")?,
            p.to_string()
        ],
    )?;
    Ok(())
}
pub fn full(db: &Connection, q: &Value) -> ApiResult<Value> {
    let stored: Option<String> = db
        .query_row(
            "SELECT json FROM reply_progress WHERE request=?1",
            [string(q, "requestId")?],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(stored) = stored {
        return Ok(serde_json::from_str(&stored)?);
    }
    let response: Option<String> = db
        .query_row(
            "SELECT id FROM responses WHERE request=?1",
            [string(q, "requestId")?],
            |r| r.get(0),
        )
        .optional()?;
    Ok(response.map(|r| empty(q, &r, None)).unwrap_or(Value::Null))
}
pub fn attach(db: &Connection, q: &mut Value, native: bool) -> ApiResult<()> {
    q["bindingDigest"] = json!(binding_digest(q));
    let mut p = full(db, q)?;
    if !native && p.is_object() {
        for key in ["received", "continued"] {
            if let Some(at) = p[key].get("at").cloned() {
                p[key] = json!({"at":at});
            }
        }
    }
    q["replyProgress"] = p;
    Ok(())
}
fn hex_digest(v: &Value) -> bool {
    v.as_str()
        .is_some_and(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
}
fn validate_proof(p: &Value, engine: &str, continued: bool) -> ApiResult<()> {
    let allowed = match (engine, continued) {
        ("codex", false) => &["codex.function_call_output"][..],
        ("codex", true) => &["codex.next_item", "codex.turn_completed"][..],
        ("claude", false) => &["claude.tool_result"][..],
        ("claude", true) => &["claude.assistant"][..],
        _ => &[][..],
    };
    identifier(p, "proofId")?;
    if !allowed.contains(&p["kind"].as_str().unwrap_or(""))
        || !hex_digest(&p["sourceDigest"])
        || p["position"].as_u64().is_none_or(|n| n == 0)
    {
        return Err(error(400, "invalid native proof"));
    }
    let allowed_keys = [
        "proofId",
        "kind",
        "sourceDigest",
        "position",
        "receivedProofId",
    ];
    if p.as_object()
        .is_none_or(|o| o.keys().any(|k| !allowed_keys.contains(&k.as_str())))
    {
        return Err(error(400, "unsupported native proof field"));
    }
    Ok(())
}
fn proof_without_time(p: &Value) -> Value {
    let mut p = p.clone();
    if let Some(o) = p.as_object_mut() {
        o.remove("at");
    }
    p
}
/// Merge inside the same transaction as the legacy receipt. Never erase a proven step.
pub fn merge_receipt(tx: &Transaction<'_>, q: &Value, v: &Value, time: i64) -> ApiResult<bool> {
    if v.get("nativeObservation").is_some() && v.get("replyProgress").is_some() {
        return Err(error(
            409,
            "source uncertainty cannot accompany an attributed proof",
        ));
    }
    if let Some(observation) = v.get("nativeObservation") {
        if observation != "answerSourceUnconfirmed" || v["state"] != "adopted" {
            return Err(error(400, "invalid native observation"));
        }
        let mut p = full(tx, q)?;
        if !p.is_object() {
            return Err(error(409, "no submitted response for observation"));
        }
        if !p["received"].is_null() {
            return Err(error(
                409,
                "source uncertainty cannot replace attributed reception",
            ));
        }
        let changed = p["nativeObservation"] != *observation;
        p["nativeObservation"] = observation.clone();
        tx.execute("INSERT INTO reply_progress VALUES(?1,?2,?3) ON CONFLICT(request) DO UPDATE SET json=excluded.json",params![string(q,"requestId")?,string(v,"responseId")?,p.to_string()])?;
        if !v.get("replyProgress").is_some() {
            return Ok(changed);
        }
    }
    let Some(incoming) = v.get("replyProgress") else {
        return Ok(false);
    };
    if incoming["schemaVersion"] != 1 || v["state"] != "adopted" {
        return Err(error(400, "invalid progress version or state"));
    }
    for key in IDENTITY {
        if incoming[*key] != q[*key] {
            return Err(error(409, "native proof binding mismatch"));
        }
    }
    if incoming["bindingDigest"] != binding_digest(q) || incoming["responseId"] != v["responseId"] {
        return Err(error(409, "native proof answer mismatch"));
    }
    let mut p = full(tx, q)?;
    if !p.is_object() || p["responseId"] != v["responseId"] {
        return Err(error(409, "no submitted response for proof"));
    }
    let engine = q["engine"].as_str().unwrap_or("");
    validate_proof(&incoming["received"], engine, false)?;
    if !incoming["continued"].is_null() {
        validate_proof(&incoming["continued"], engine, true)?;
        if incoming["continued"]["receivedProofId"] != incoming["received"]["proofId"]
            || incoming["continued"]["position"].as_u64()
                <= incoming["received"]["position"].as_u64()
        {
            return Err(error(409, "continuation must follow original reception"));
        }
    }
    let observation = incoming["continuationObservation"].as_str().unwrap_or("");
    if !["awaiting", "unknown", "unsupported", "confirmed"].contains(&observation)
        || (observation == "confirmed") != !incoming["continued"].is_null()
    {
        return Err(error(400, "invalid continuation observation"));
    }
    let before = p.clone();
    p.as_object_mut().unwrap().remove("nativeObservation");
    for stage in ["received", "continued"] {
        if incoming[stage].is_null() {
            continue;
        }
        if !p[stage].is_null() && proof_without_time(&p[stage]) != incoming[stage] {
            return Err(error(409, "conflicting native proof"));
        }
        if p[stage].is_null() {
            p[stage] = incoming[stage].clone();
            p[stage]["at"] = json!(time);
        }
    }
    if !p["continued"].is_null() {
        p["continuationObservation"] = json!("confirmed");
    } else if p["continuationObservation"] == "unobserved" || observation != "awaiting" {
        p["continuationObservation"] = json!(observation);
    }
    tx.execute("INSERT INTO reply_progress VALUES(?1,?2,?3) ON CONFLICT(request) DO UPDATE SET json=excluded.json",params![string(q,"requestId")?,string(v,"responseId")?,p.to_string()])?;
    Ok(p != before)
}
