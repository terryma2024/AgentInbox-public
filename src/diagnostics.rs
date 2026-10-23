//! Authenticated operational diagnostics. Share exports are a separate client whitelist.
use crate::{model::*, store::Store};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub fn install(db: &Connection) -> ApiResult<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS diagnostic_hosts(host TEXT PRIMARY KEY,at INTEGER NOT NULL,json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS diagnostic_tests(id TEXT PRIMARY KEY,device TEXT NOT NULL,host TEXT NOT NULL,created INTEGER NOT NULL,expires INTEGER NOT NULL,phase TEXT NOT NULL,code TEXT,request TEXT UNIQUE,mode TEXT NOT NULL DEFAULT 'reply'); CREATE INDEX IF NOT EXISTS diagnostic_tests_due ON diagnostic_tests(host,phase,expires);")?;
    Ok(())
}
// Unknown strings are rejected, never stored as errors or displayed verbatim.
pub const CODES: &[&str] = &[
    "nativeStartFailed",
    "nativeUnavailable",
    "nativeTimeout",
    "hostDraining",
    "reconciliationPending",
    "testInterrupted",
    "pushOnly",
];
pub fn heartbeat(body: &Value, time: i64) -> ApiResult<Value> {
    let codex = string(body, "codex")?;
    let claude = string(body, "claude")?;
    if !["ready", "starting", "disabled", "failed"].contains(&codex)
        || !["observed", "unobserved"].contains(&claude)
    {
        return Err(error(400, "invalid adapter observation"));
    }
    let scan = body["scanAt"].as_i64().filter(|at| *at > 0 && *at <= time);
    Ok(
        json!({"codex":codex,"claude":claude,"scanAt":scan,"hookAt":body["hookAt"].as_i64().filter(|at| *at > 0 && *at <= time),"reconciled":body["reconciled"].as_bool().unwrap_or(false),"draining":body["draining"].as_bool().unwrap_or(false),"nativeProof":body["nativeProof"].as_bool().unwrap_or(false)}),
    )
}
pub(crate) fn authorize_request(db: &Connection, request: &str, device: &str) -> ApiResult<()> {
    let owner: Option<String> = db
        .query_row(
            "SELECT device FROM diagnostic_tests WHERE request=?1",
            [request],
            |r| r.get(0),
        )
        .optional()?;
    if owner.is_some_and(|owner| owner != device) {
        return Err(error(403, "diagnostic test belongs to another device"));
    }
    Ok(())
}
impl Store {
    pub fn diagnostic_heartbeat(&self, host: &str, body: &Value, time: i64) -> ApiResult<()> {
        let observation = heartbeat(body, time)?;
        self.db.lock().unwrap().execute("INSERT INTO diagnostic_hosts VALUES(?1,?2,?3) ON CONFLICT(host) DO UPDATE SET at=excluded.at,json=excluded.json",params![host,time,observation.to_string()])?;
        Ok(())
    }
    pub fn diagnostic_snapshot(&self, device: &str, time: i64) -> ApiResult<Value> {
        let db = self.db.lock().unwrap();
        let mut stmt = db.prepare("SELECT h.id,h.last_seen,d.at,d.json FROM hosts h LEFT JOIN diagnostic_hosts d ON d.host=h.id ORDER BY h.id LIMIT 200")?;
        let mut hosts = Vec::new();
        for row in stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, Option<i64>>(2)?,
                r.get::<_, Option<String>>(3)?,
            ))
        })? {
            let (host, seen, at, body) = row?;
            let observation: Value = body
                .map(|s| serde_json::from_str(&s))
                .transpose()?
                .unwrap_or(Value::Null);
            hosts.push(json!({"hostId":host,"lastSeen":seen,"online":time>=seen && time-seen<30,"observedAt":at,"observation":observation}));
        }
        let registered: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM devices WHERE id=?1 AND active=1)",
            [device],
            |r| r.get(0),
        )?;
        let tests = {
            let mut stmt = db.prepare(
                "SELECT id FROM diagnostic_tests WHERE device=?1 ORDER BY created DESC LIMIT 10",
            )?;
            stmt.query_map([device], |r| r.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        Ok(
            json!({"schemaVersion":1,"checkedAt":time,"hosts":hosts,"pushRegistered":registered,"recentTestIds":tests}),
        )
    }
    pub fn start_diagnostic(&self, device: &str, body: &Value, time: i64) -> ApiResult<Value> {
        let id = identifier(body, "testId")?;
        let host = identifier(body, "hostId")?;
        let mode = body["mode"].as_str().unwrap_or("reply");
        if !["push", "reply"].contains(&mode) {
            return Err(error(400, "invalid diagnostic mode"));
        }
        {
            let mut db = self.db.lock().unwrap();
            let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let old: Option<(String, String, String)> = tx
                .query_row(
                    "SELECT device,host,mode FROM diagnostic_tests WHERE id=?1",
                    [&id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()?;
            if let Some((owner, old_host, old_mode)) = old {
                if owner != device || old_host != host || old_mode != mode {
                    return Err(error(409, "diagnostic identity conflict"));
                }
            } else {
                let busy:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM diagnostic_tests WHERE host=?1 AND expires>?2 AND mode=?3 AND phase IN ('queued','starting','ready') AND NOT EXISTS(SELECT 1 FROM reply_progress p WHERE p.request=diagnostic_tests.request AND json_extract(p.json,'$.continued.at') IS NOT NULL))",params![host,time,mode],|r|r.get(0))?;
                if busy {
                    return Err(error(409, "a diagnostic is already active on this host"));
                }
                tx.execute("INSERT INTO diagnostic_tests(id,device,host,created,expires,phase,mode) VALUES(?1,?2,?3,?4,?5,?6,?7)",params![id,device,host,time,time+180,if mode=="push" {"starting"} else {"queued"},mode])?;
                tx.commit()?;
            }
        }
        let prior = self.diagnostic_test(device, &id, time)?;
        if mode == "push"
            && prior["phase"] == "starting"
            && prior["request"].is_null()
            && prior["expiresAt"]
                .as_i64()
                .is_some_and(|expiry| expiry > time)
        {
            // No original call exists for this notification-only test.
            let q = json!({"requestId":format!("diagnostic-push-{:x}",Sha256::digest(id.as_bytes())),"hostId":host,"engine":"diagnostic","runtimeId":id,"sessionId":id,"nativeRequestId":id,"revision":1,"expiresAt":prior["expiresAt"],"kind":"choice","title":"推送自检","body":"这是无敏感内容的测试通知。","options":[{"id":"ok","label":"确认"}],"multiSelect":false,"diagnosticTestId":id});
            self.create(&host, q, time)?;
        }
        self.diagnostic_test(device, &id, time)
    }
    pub fn claim_diagnostic(&self, host: &str, time: i64) -> ApiResult<Value> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let job:Option<(String,i64)>=tx.query_row("SELECT id,expires FROM diagnostic_tests WHERE host=?1 AND mode='reply' AND phase='queued' AND expires>?2 AND device NOT IN (SELECT id FROM revoked_credentials) ORDER BY created LIMIT 1",params![host,time],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((id, expires)) = job {
            tx.execute(
                "UPDATE diagnostic_tests SET phase='starting' WHERE id=?1",
                [&id],
            )?;
            tx.commit()?;
            Ok(json!({"test":{"testId":id,"expiresAt":expires}}))
        } else {
            Ok(json!({"test":null}))
        }
    }
    pub fn update_diagnostic(&self, host: &str, body: &Value, time: i64) -> ApiResult<Value> {
        let id = identifier(body, "testId")?;
        let phase = string(body, "phase")?;
        if !["unsupported", "failed"].contains(&phase) {
            return Err(error(400, "invalid diagnostic phase"));
        }
        let code = string(body, "code")?;
        if !CODES.contains(&code) {
            return Err(error(400, "invalid diagnostic code"));
        }
        let db = self.db.lock().unwrap();
        let n=db.execute("UPDATE diagnostic_tests SET phase=?1,code=?2 WHERE id=?3 AND host=?4 AND expires>?5 AND phase IN ('starting','ready')",params![phase,code,id,host,time])?;
        if n != 1 {
            return Err(error(409, "diagnostic unavailable or already terminal"));
        }
        Ok(json!({"updated":true}))
    }
    pub fn diagnostic_test(&self, device: &str, id: &str, time: i64) -> ApiResult<Value> {
        let (host, created, expires, phase, code, request, mode, registered, push) = {
            let db = self.db.lock().unwrap();
            let row = db.query_row("SELECT host,created,expires,phase,code,request,mode FROM diagnostic_tests WHERE id=?1 AND device=?2",params![id,device],|r|Ok((r.get::<_,String>(0)?,r.get::<_,i64>(1)?,r.get::<_,i64>(2)?,r.get::<_,String>(3)?,r.get::<_,Option<String>>(4)?,r.get::<_,Option<String>>(5)?,r.get::<_,String>(6)?))).optional()?.ok_or_else(||error(404,"diagnostic test not found"))?;
            let registered: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM devices WHERE id=?1 AND active=1)",
                [device],
                |r| r.get(0),
            )?;
            let push: Option<String> = db
                .query_row(
                    "SELECT state FROM outbox WHERE request=?1 AND device=?2",
                    params![row.5, device],
                    |r| r.get(0),
                )
                .optional()?;
            (
                row.0, row.1, row.2, row.3, row.4, row.5, row.6, registered, push,
            )
        };
        let q = request
            .as_deref()
            .map(|id| self.get(id, false))
            .transpose()?
            .unwrap_or(Value::Null);
        let submitted = q["replyProgress"]["submitted"]["at"].is_number();
        let received = q["replyProgress"]["received"]["at"].is_number();
        let continued = received && q["replyProgress"]["continued"]["at"].is_number();
        let phase = if continued {
            "complete"
        } else if expires <= time && !["unsupported", "failed"].contains(&phase.as_str()) {
            "expired"
        } else {
            &phase
        };
        let push = match push.as_deref() {
            Some("sent") => "accepted",
            Some("failed") => "failed",
            Some("pending") => "queued",
            Some("cancelled") => "cancelled",
            _ if !registered => "unregistered",
            _ => "unobserved",
        };
        Ok(
            json!({"testId":id,"hostId":host,"createdAt":created,"expiresAt":expires,"phase":phase,"code":code,"mode":mode,"request":q,"push":push,"submitted":submitted,"received":received,"continued":continued}),
        )
    }
    pub fn authorize_diagnostic_request(&self, request: &str, device: &str) -> ApiResult<()> {
        authorize_request(&self.db.lock().unwrap(), request, device)
    }
}
