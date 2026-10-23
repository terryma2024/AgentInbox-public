use crate::model::*;
use crate::reply_progress;
use crate::widget_push::{
    MAX_WIDGET_ATTEMPTS, WIDGET_COALESCE_SECONDS, WIDGET_MIN_INTERVAL_SECONDS, WidgetDelivery,
    WidgetJob,
};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{path::Path, sync::Mutex};
pub struct Store {
    pub(crate) db: Mutex<Connection>,
}
impl Store {
    pub fn open(path: impl AsRef<Path>) -> ApiResult<Self> {
        let mut db = Connection::open(path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS requests(id TEXT PRIMARY KEY,host TEXT NOT NULL,binding TEXT UNIQUE NOT NULL,state TEXT NOT NULL,expires INTEGER NOT NULL,json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS responses(id TEXT PRIMARY KEY,request TEXT UNIQUE NOT NULL,device TEXT NOT NULL,json TEXT NOT NULL,claimed INTEGER NOT NULL DEFAULT 0,FOREIGN KEY(request) REFERENCES requests(id)); CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,token TEXT NOT NULL,environment TEXT NOT NULL,active INTEGER NOT NULL DEFAULT 1); CREATE TABLE IF NOT EXISTS outbox(id INTEGER PRIMARY KEY,request TEXT NOT NULL,device TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,next INTEGER NOT NULL DEFAULT 0,error TEXT); CREATE UNIQUE INDEX IF NOT EXISTS outbox_unique ON outbox(request,device); CREATE TABLE IF NOT EXISTS hosts(id TEXT PRIMARY KEY,last_seen INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS revoked_credentials(id TEXT PRIMARY KEY); CREATE TABLE IF NOT EXISTS device_credentials(id TEXT PRIMARY KEY,hash TEXT UNIQUE NOT NULL,name TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS pair_codes(hash TEXT PRIMARY KEY,expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS pair_rate(id INTEGER PRIMARY KEY CHECK(id=1),window INTEGER NOT NULL,attempts INTEGER NOT NULL);")?;
        db.execute_batch("CREATE TABLE IF NOT EXISTS widget_tokens(device TEXT PRIMARY KEY,token TEXT NOT NULL,environment TEXT NOT NULL,active INTEGER NOT NULL,version INTEGER NOT NULL,blocked_reason TEXT,registration_revision INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS widget_updates(device TEXT PRIMARY KEY,generation INTEGER NOT NULL,acked INTEGER NOT NULL DEFAULT 0,snapshot TEXT NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,next INTEGER NOT NULL DEFAULT 0,error TEXT); CREATE INDEX IF NOT EXISTS widget_updates_due ON widget_updates(state,next);")?;
        let has_revision:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM pragma_table_info('widget_tokens') WHERE name='registration_revision')",[],|r|r.get(0))?;
        if !has_revision {
            db.execute_batch("ALTER TABLE widget_tokens ADD COLUMN registration_revision INTEGER NOT NULL DEFAULT 0;")?;
        }
        reply_progress::install(&db)?;
        crate::diagnostics::install(&db)?;
        {
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            tx.execute("UPDATE requests SET state='unknown' WHERE state='submitting' AND id IN (SELECT request FROM responses WHERE claimed=1)",[])?;
            // Reconcile changes made during an older-binary rollback without replaying answers.
            enqueue_widget_changes(&tx, now())?;
            tx.commit()?;
        }
        Ok(Self { db: Mutex::new(db) })
    }
    pub fn create(&self, host: &str, mut v: Value, time: i64) -> ApiResult<Value> {
        let id = identifier(&v, "requestId")?;
        if string(&v, "hostId")? != host {
            return Err(error(403, "host binding mismatch"));
        }
        for f in ["engine", "runtimeId", "sessionId", "nativeRequestId"] {
            string(&v, f)?;
        }
        if v["revision"].as_i64() != Some(1) {
            return Err(error(400, "initial revision must be 1"));
        }
        let exp = v["expiresAt"]
            .as_i64()
            .ok_or_else(|| error(400, "missing expiresAt"))?;
        if exp <= time {
            return Err(error(409, "request expired"));
        }
        let kind = string(&v, "kind")?;
        if !["choice", "text", "permission", "questions", "multiSelect"].contains(&kind) {
            return Err(error(400, "unsupported request kind"));
        }
        validate_options(&v)?;
        v["state"] = json!("pending");
        v["createdAt"] = json!(time);
        v["updatedAt"] = json!(time);
        let binding = serde_json::to_string(&json!([
            host,
            v["engine"],
            v["runtimeId"],
            v["sessionId"],
            v["turnId"],
            v["nativeRequestId"],
            v["itemId"]
        ]))?;
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        if let Some((old_id, old, current_state)) = tx
            .query_row(
                "SELECT id,json,state FROM requests WHERE binding=?1 OR id=?2",
                params![binding, id],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()?
        {
            let mut old: Value = serde_json::from_str(&old)?;
            let mut compare = old.clone();
            for f in ["createdAt", "updatedAt", "state"] {
                compare[f] = v[f].clone();
            }
            if old_id == id && compare == v {
                old["state"] = json!(current_state);
                return Ok(view(old, false));
            }
            return Err(error(409, "native binding or requestId already exists"));
        }
        let diagnostic_device: Option<String> = if let Some(test) = v["diagnosticTestId"].as_str() {
            let owner: Option<String> = tx.query_row("SELECT device FROM diagnostic_tests WHERE id=?1 AND host=?2 AND phase='starting' AND expires>=?3 AND request IS NULL",params![test,host,exp],|r|r.get(0)).optional()?;
            if owner.is_none() {
                return Err(error(409, "diagnostic binding unavailable"));
            }
            tx.execute(
                "UPDATE diagnostic_tests SET request=?1,phase='ready' WHERE id=?2",
                params![id, test],
            )?;
            owner
        } else {
            None
        };
        tx.execute(
            "INSERT INTO requests VALUES(?1,?2,?3,'pending',?4,?5)",
            params![id, host, binding, exp, v.to_string()],
        )?;
        tx.execute(
            "INSERT INTO outbox(request,device) SELECT ?1,id FROM devices WHERE active=1 AND (?2 IS NULL OR id=?2)",
            params![id,diagnostic_device],
        )?;
        enqueue_widget_changes(&tx, time)?;
        tx.commit()?;
        Ok(view(v, false))
    }
    pub fn get(&self, id: &str, native: bool) -> ApiResult<Value> {
        let db = self.db.lock().unwrap();
        let row = db
            .query_row("SELECT json,state FROM requests WHERE id=?1", [id], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })
            .optional()?
            .ok_or_else(|| error(404, "request not found"))?;
        let mut v: Value = serde_json::from_str(&row.0)?;
        v["state"] = json!(row.1);
        v["responseId"] = db
            .query_row("SELECT id FROM responses WHERE request=?1", [id], |r| {
                r.get::<_, String>(0)
            })
            .optional()?
            .map(Value::String)
            .unwrap_or(Value::Null);
        reply_progress::attach(&db, &mut v, native)?;
        Ok(view(v, native))
    }
    pub fn list(&self, time: i64) -> ApiResult<Vec<Value>> {
        let mut db = self.db.lock().unwrap();
        {
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            expire_widget_requests(&tx, None, time)?;
            tx.commit()?;
        }
        let mut stmt =
            db.prepare("SELECT json,state,id FROM requests WHERE json_extract(json,'$.diagnosticTestId') IS NULL ORDER BY rowid DESC LIMIT 200")?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?;
        let mut out = vec![];
        for row in rows {
            let (j, s, id) = row?;
            let mut v: Value = serde_json::from_str(&j)?;
            v["state"] = json!(s);
            v["responseId"] = db
                .query_row("SELECT id FROM responses WHERE request=?1", [id], |r| {
                    r.get::<_, String>(0)
                })
                .optional()?
                .map(Value::String)
                .unwrap_or(Value::Null);
            reply_progress::attach(&db, &mut v, false)?;
            out.push(view(v, false));
        }
        Ok(out)
    }
    /// Complete, host-scoped startup snapshot; UI history pagination must not hide live callbacks.
    pub fn active_for_host(&self, host: &str, time: i64) -> ApiResult<Vec<Value>> {
        let mut db = self.db.lock().unwrap();
        {
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            expire_widget_requests(&tx, Some(host), time)?;
            tx.commit()?;
        }
        let mut stmt = db.prepare("SELECT r.json,r.state,p.id FROM requests r LEFT JOIN responses p ON p.request=r.id WHERE r.host=?1 AND r.state IN ('pending','submitting') ORDER BY r.rowid")?;
        let rows = stmt.query_map([host], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (encoded, state, response_id) = row?;
            let mut q: Value = serde_json::from_str(&encoded)?;
            q["state"] = json!(state);
            q["responseId"] = response_id.map(Value::String).unwrap_or(Value::Null);
            reply_progress::attach(&db, &mut q, true)?;
            out.push(view(q, true));
        }
        Ok(out)
    }
    /// Counts every unresolved result for this authenticated host, including unknowns omitted from the startup callback snapshot.
    pub fn upgrade_status(&self, host: &str, time: i64) -> ApiResult<Value> {
        let mut db = self.db.lock().unwrap();
        {
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            expire_widget_requests(&tx, Some(host), time)?;
            tx.commit()?;
        }
        let (pending,submitting,unknown): (i64,i64,i64) = db.query_row(
            "SELECT COALESCE(SUM(state='pending'),0),COALESCE(SUM(state='submitting'),0),COALESCE(SUM(state='unknown'),0) FROM requests WHERE host=?1 AND state IN ('pending','submitting','unknown')",
            [host], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
        let awaiting:i64=db.query_row("SELECT COUNT(*) FROM reply_progress p JOIN requests r ON r.id=p.request WHERE r.host=?1 AND json_extract(p.json,'$.continuationObservation')='awaiting'",[host],|r|r.get(0))?;
        Ok(
            json!({"hostId":host,"pending":pending,"submitting":submitting,"unknown":unknown+awaiting,"unknownRequests":unknown,"awaitingContinuation":awaiting}),
        )
    }
    pub fn respond(&self, device: &str, a: Value, time: i64) -> ApiResult<Value> {
        let rid = identifier(&a, "responseId")?;
        let id = identifier(&a, "requestId")?;
        let payload = a.to_string();
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        crate::diagnostics::authorize_request(&tx, &id, device)?;
        if let Some((old, owner)) = tx
            .query_row(
                "SELECT json,device FROM responses WHERE id=?1",
                [&rid],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?
        {
            if old == payload && owner == device {
                let state: String =
                    tx.query_row("SELECT state FROM requests WHERE id=?1", [&id], |r| {
                        r.get(0)
                    })?;
                let q: String =
                    tx.query_row("SELECT json FROM requests WHERE id=?1", [&id], |r| r.get(0))?;
                let q: Value = serde_json::from_str(&q)?;
                let mut result = json!({"requestId":id,"responseId":rid,"state":state});
                result["bindingDigest"] = json!(reply_progress::binding_digest(&q));
                let mut projection = q.clone();
                reply_progress::attach(&tx, &mut projection, false)?;
                result["replyProgress"] = projection["replyProgress"].clone();
                return Ok(result);
            }
            return Err(error(409, "responseId content or owner conflict"));
        }
        let (j, state, exp): (String, String, i64) = tx
            .query_row(
                "SELECT json,state,expires FROM requests WHERE id=?1",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
            .ok_or_else(|| error(404, "request not found"))?;
        if state != "pending" || exp <= time {
            return Err(error(409, "request no longer pending"));
        }
        let q: Value = serde_json::from_str(&j)?;
        if a.get("bindingDigest")
            .is_some_and(|d| d != &json!(reply_progress::binding_digest(&q)))
        {
            return Err(error(409, "content fingerprint mismatch"));
        }
        if q["revision"] != a["revision"] {
            return Err(error(409, "revision mismatch"));
        }
        validate_answer(&q, &a)?;
        tx.execute(
            "INSERT INTO responses(id,request,device,json) VALUES(?1,?2,?3,?4)",
            params![rid, id, device, payload],
        )?;
        reply_progress::record_submission(&tx, &q, &a, time)?;
        tx.execute("UPDATE requests SET state='submitting' WHERE id=?1", [&id])?;
        enqueue_widget_changes(&tx, time)?;
        let mut projection = q.clone();
        reply_progress::attach(&tx, &mut projection, false)?;
        tx.commit()?;
        Ok(
            json!({"requestId":id,"responseId":rid,"state":"submitting","bindingDigest":projection["bindingDigest"],"replyProgress":projection["replyProgress"]}),
        )
    }
    pub fn claim(&self, host: &str, time: i64) -> ApiResult<Vec<Value>> {
        self.claim_filtered(host, None, time)
    }
    pub fn claim_one(&self, host: &str, id: &str, time: i64) -> ApiResult<Vec<Value>> {
        self.claim_filtered(host, Some(id), time)
    }
    fn claim_filtered(&self, host: &str, filter: Option<&str>, time: i64) -> ApiResult<Vec<Value>> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        expire_widget_requests(&tx, Some(host), time)?;
        let entries = {
            let mut stmt=tx.prepare("SELECT responses.id,responses.json FROM responses JOIN requests ON requests.id=responses.request WHERE requests.host=?1 AND requests.state='submitting' AND responses.claimed=0 AND requests.expires>?2 AND (?3 IS NULL OR requests.id=?3)")?;
            stmt.query_map(params![host, time, filter], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
        };
        let mut out = vec![];
        for (id, j) in entries {
            tx.execute("UPDATE responses SET claimed=1 WHERE id=?1", [id])?;
            out.push(serde_json::from_str(&j)?)
        }
        tx.execute("INSERT INTO hosts VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen",params![host,time])?;
        tx.commit()?;
        Ok(out)
    }
    pub fn receipt(&self, host: &str, v: Value, time: i64) -> ApiResult<Value> {
        let id = identifier(&v, "requestId")?;
        let target = string(&v, "state")?;
        if ![
            "adopted",
            "handledLocally",
            "expired",
            "invalidated",
            "unknown",
        ]
        .contains(&target)
        {
            return Err(error(400, "invalid receipt state"));
        }
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        let (h, current, j): (String, String, String) = tx
            .query_row(
                "SELECT host,state,json FROM requests WHERE id=?1",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
            .ok_or_else(|| error(404, "request not found"))?;
        if h != host {
            return Err(error(403, "host binding mismatch"));
        }
        let response: Option<(String, i64)> = tx
            .query_row(
                "SELECT id,claimed FROM responses WHERE request=?1",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((rid, claimed)) = response {
            if v["responseId"] != rid {
                return Err(error(409, "response binding mismatch"));
            }
            if target == "adopted"
                && (claimed != 1 || v["evidence"].is_null() || v["evidence"] == json!(""))
            {
                return Err(error(
                    409,
                    "adoption requires claimed response and native evidence",
                ));
            }
        } else if target == "adopted" || !v["responseId"].is_null() {
            return Err(error(409, "no matching response"));
        }
        if current != target && !["pending", "submitting", "unknown"].contains(&current.as_str()) {
            return Err(error(409, "terminal request"));
        }
        if current == "pending" && target == "unknown" {
            return Err(error(409, "pending request cannot be unknown"));
        }
        let mut q: Value = serde_json::from_str(&j)?;
        let progress_changed = reply_progress::merge_receipt(&tx, &q, &v, time)?;
        q["state"] = json!(target);
        q["updatedAt"] = json!(time);
        q["evidence"] = v["evidence"].clone();
        tx.execute(
            "UPDATE requests SET state=?1,json=?2 WHERE id=?3",
            params![target, q.to_string(), id],
        )?;
        if current != target || progress_changed {
            enqueue_widget_changes(&tx, time)?;
        }
        reply_progress::attach(&tx, &mut q, false)?;
        tx.commit()?;
        Ok(view(q, false))
    }
    pub fn incomplete_progress(&self, host: &str) -> ApiResult<Vec<Value>> {
        let db = self.db.lock().unwrap();
        let mut stmt=db.prepare("SELECT r.json,r.state,p.response FROM requests r JOIN reply_progress p ON p.request=r.id WHERE r.host=?1 AND json_extract(p.json,'$.continuationObservation')='awaiting'")?;
        let rows = stmt.query_map([host], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (j, state, rid) = row?;
            let mut q: Value = serde_json::from_str(&j)?;
            q["state"] = json!(state);
            q["responseId"] = json!(rid);
            reply_progress::attach(&db, &mut q, true)?;
            out.push(q);
        }
        Ok(out)
    }
    pub fn device_token(&self, id: &str, token: &str, env: &str) -> ApiResult<Value> {
        if !["sandbox", "production"].contains(&env)
            || token.len() < 32
            || token.len() > 256
            || !token.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(error(400, "invalid APNs token/environment"));
        }
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        tx.execute("INSERT INTO devices VALUES(?1,?2,?3,1) ON CONFLICT(id) DO UPDATE SET token=excluded.token,environment=excluded.environment,active=1",params![id,token,env])?;
        tx.execute("INSERT OR IGNORE INTO outbox(request,device) SELECT r.id,?1 FROM requests r WHERE r.state='pending' AND r.expires>?2 AND (json_extract(r.json,'$.diagnosticTestId') IS NULL OR EXISTS(SELECT 1 FROM diagnostic_tests t WHERE t.request=r.id AND t.device=?1))",params![id,now()])?;
        tx.commit()?;
        Ok(json!({"registered":true}))
    }
    pub fn revoke_device(&self, id: &str) -> ApiResult<()> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        revoke_device_transaction(&tx, id)?;
        tx.commit()?;
        Ok(())
    }
    pub fn is_revoked(&self, id: &str) -> ApiResult<bool> {
        let db = self.db.lock().unwrap();
        Ok(db
            .query_row(
                "SELECT 1 FROM revoked_credentials WHERE id=?1",
                [id],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }
    pub fn device_credential(&self, token: &str) -> ApiResult<Option<String>> {
        let db = self.db.lock().unwrap();
        Ok(db.query_row("SELECT id FROM device_credentials WHERE hash=?1 AND revoked=0 AND id NOT IN (SELECT id FROM revoked_credentials)",[hash(token)],|r|r.get(0)).optional()?)
    }
    pub fn add_pair_code(&self, code: &str, time: i64) -> ApiResult<()> {
        if code.len() < 8 || code.len() > 128 {
            return Err(error(400, "invalid pair code length"));
        }
        let db = self.db.lock().unwrap();
        db.execute(
            "INSERT INTO pair_codes VALUES(?1,?2,0)",
            params![hash(code), time + 600],
        )?;
        Ok(())
    }
    pub fn pair(&self, code: &str, name: &str, time: i64) -> ApiResult<Value> {
        if code.len() > 128 || name.len() > 128 {
            return Err(error(400, "invalid pairing input"));
        }
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        let rate: Option<(i64, i64)> = tx
            .query_row(
                "SELECT window,attempts FROM pair_rate WHERE id=1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if rate.is_some_and(|(window, count)| time - window < 60 && count >= 5) {
            return Err(error(429, "pairing temporarily rate limited"));
        }
        let valid: bool = tx
            .query_row(
                "SELECT 1 FROM pair_codes WHERE hash=?1 AND used=0 AND expires>?2",
                params![hash(code), time],
                |_| Ok(true),
            )
            .optional()?
            .unwrap_or(false);
        if !valid {
            let (window, count) = rate
                .filter(|(window, _)| time - window < 60)
                .unwrap_or((time, 0));
            tx.execute("INSERT INTO pair_rate VALUES(1,?1,?2) ON CONFLICT(id) DO UPDATE SET window=excluded.window,attempts=excluded.attempts",params![window,count+1])?;
            tx.commit()?;
            return Err(error(401, "pair code invalid, expired or used"));
        }
        let id = format!("device-{}", uuid::Uuid::new_v4());
        let token = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        tx.execute("UPDATE pair_codes SET used=1 WHERE hash=?1", [hash(code)])?;
        tx.execute(
            "INSERT INTO device_credentials(id,hash,name) VALUES(?1,?2,?3)",
            params![id, hash(&token), name],
        )?;
        tx.commit()?;
        Ok(json!({"deviceId":id,"token":token}))
    }
    pub fn heartbeat(&self, host: &str, time: i64) -> ApiResult<Value> {
        let db = self.db.lock().unwrap();
        db.execute("INSERT INTO hosts VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen", params![host,time])?;
        Ok(json!({"hostId":host,"online":true,"lastSeen":time}))
    }
    pub fn hosts(&self, time: i64) -> ApiResult<Value> {
        let db = self.db.lock().unwrap();
        let mut stmt = db.prepare("SELECT id,last_seen FROM hosts")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        let mut hs = vec![];
        for r in rows {
            let (id, t) = r?;
            hs.push(json!({"hostId":id,"name":id,"online":time-t<30,"lastSeen":t}))
        }
        Ok(json!({"hosts":hs}))
    }
    pub fn push_batch(&self, time: i64) -> ApiResult<Vec<Value>> {
        let db = self.db.lock().unwrap();
        let mut stmt=db.prepare("SELECT o.id,o.request,d.token,d.environment,o.attempts,r.expires,json_extract(r.json,'$.diagnosticTestId') FROM outbox o JOIN devices d ON d.id=o.device JOIN requests r ON r.id=o.request WHERE o.state='pending' AND o.next<=?1 AND d.active=1 AND r.state='pending' AND r.expires>?1 LIMIT 20")?;
        let rows=stmt.query_map([time],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"requestId":r.get::<_,String>(1)?,"token":r.get::<_,String>(2)?,"environment":r.get::<_,String>(3)?,"attempts":r.get::<_,i64>(4)?,"expiresAt":r.get::<_,i64>(5)?,"diagnosticTestId":r.get::<_,Option<String>>(6)?})))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }
    /// Reauthorize a previously fetched job immediately before starting HTTP.
    /// Already authorized/in-flight APNs requests cannot be recalled.
    pub fn push_job_authorized(&self, id: i64, time: i64) -> ApiResult<bool> {
        let db = self.db.lock().unwrap();
        Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM outbox o JOIN devices d ON d.id=o.device JOIN requests r ON r.id=o.request WHERE o.id=?1 AND o.state='pending' AND o.next<=?2 AND d.active=1 AND r.state='pending' AND r.expires>?2 AND NOT EXISTS(SELECT 1 FROM revoked_credentials v WHERE v.id=o.device) AND NOT EXISTS(SELECT 1 FROM device_credentials c WHERE c.id=o.device AND c.revoked<>0))",params![id,time],|r|r.get(0))?)
    }
    pub fn invalidate_push_token(&self, token: &str) -> ApiResult<()> {
        let db = self.db.lock().unwrap();
        db.execute("UPDATE devices SET active=0 WHERE token=?1", [token])?;
        db.execute("UPDATE outbox SET state='cancelled' WHERE state='pending' AND device IN (SELECT id FROM devices WHERE token=?1)",[token])?;
        Ok(())
    }
    pub fn push_result(&self, id: i64, ok: bool, permanent: bool, time: i64) -> ApiResult<()> {
        let db = self.db.lock().unwrap();
        db.execute(
            "UPDATE outbox SET state=?1,attempts=attempts+1,next=?2,error=?3 WHERE id=?4 AND state='pending'",
            params![
                if ok {
                    "sent"
                } else if permanent {
                    "failed"
                } else {
                    "pending"
                },
                time + 60,
                if ok {
                    None
                } else {
                    Some("APNs delivery failed")
                },
                id
            ],
        )?;
        Ok(())
    }
}
/// All callers commit the same four revocation writes in one transaction.
/// Operator callers must first verify membership in device_credentials.
pub(crate) fn revoke_device_transaction(tx: &Transaction<'_>, id: &str) -> ApiResult<()> {
    tx.execute("INSERT OR IGNORE INTO revoked_credentials VALUES(?1)", [id])?;
    tx.execute("UPDATE device_credentials SET revoked=1 WHERE id=?1", [id])?;
    tx.execute("UPDATE devices SET active=0 WHERE id=?1", [id])?;
    tx.execute(
        "UPDATE outbox SET state='cancelled' WHERE device=?1 AND state='pending'",
        [id],
    )?;
    if tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name='widget_tokens')",
        [],
        |r| r.get::<_, bool>(0),
    )? {
        tx.execute("UPDATE widget_tokens SET active=0 WHERE device=?1", [id])?;
    }
    if tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name='widget_updates')",
        [],
        |r| r.get::<_, bool>(0),
    )? {
        tx.execute(
            "UPDATE widget_updates SET state='cancelled' WHERE device=?1",
            [id],
        )?;
    }
    Ok(())
}

fn view(mut v: Value, native: bool) -> Value {
    if !native {
        v.as_object_mut().unwrap().remove("native");
    }
    v
}
fn validate_options(q: &Value) -> ApiResult<()> {
    let groups: Vec<&Value> = if q["kind"] == "questions" {
        q["questions"]
            .as_array()
            .ok_or_else(|| error(400, "questions missing"))?
            .iter()
            .collect()
    } else {
        vec![q]
    };
    if groups.is_empty() {
        return Err(error(400, "questions cannot be empty"));
    }
    let mut question_ids = std::collections::HashSet::new();
    for g in groups {
        if q["kind"] == "questions" && !question_ids.insert(identifier(g, "id")?) {
            return Err(error(400, "duplicate question ID"));
        }
        let opts = g["options"]
            .as_array()
            .ok_or_else(|| error(400, "options missing"))?;
        let mut ids = std::collections::HashSet::new();
        for o in opts {
            let id = identifier(o, "id")?;
            string(o, "label")?;
            if !ids.insert(id) {
                return Err(error(400, "duplicate option ID"));
            }
        }
    }
    Ok(())
}
fn validate_answer(q: &Value, a: &Value) -> ApiResult<()> {
    if q["kind"] == "questions" {
        if a["optionIds"].as_array().is_none_or(|ids| !ids.is_empty())
            || a["text"].as_str().is_some_and(|t| !t.is_empty())
        {
            return Err(error(
                400,
                "multi-question answers require empty top-level answer",
            ));
        }
        let questions = q["questions"]
            .as_array()
            .ok_or_else(|| error(400, "questions missing"))?;
        let answers = a["answers"]
            .as_object()
            .ok_or_else(|| error(400, "answers missing"))?;
        if answers.len() != questions.len() {
            return Err(error(400, "all question answers required"));
        }
        for question in questions {
            let id = string(question, "id")?;
            check_selection(
                question,
                answers
                    .get(id)
                    .ok_or_else(|| error(400, "missing question answer"))?,
                question["allowText"] == true,
            )?;
        }
    } else {
        if a["answers"]
            .as_object()
            .is_some_and(|answers| !answers.is_empty())
        {
            return Err(error(
                400,
                "single-question answers must use top-level fields",
            ));
        }
        check_selection(q, a, q["kind"] == "text" || q["allowText"] == true)?;
    }
    Ok(())
}
fn check_selection(q: &Value, a: &Value, allow_text: bool) -> ApiResult<()> {
    let opts = q["options"]
        .as_array()
        .ok_or_else(|| error(400, "options missing"))?;
    let selected = a["optionIds"]
        .as_array()
        .ok_or_else(|| error(400, "optionIds missing"))?;
    let mut ids = std::collections::HashSet::new();
    for id in selected {
        if !id.is_string() || !opts.iter().any(|o| o["id"] == *id) || !ids.insert(id.to_string()) {
            return Err(error(400, "invalid or repeated option ID"));
        }
    }
    if q["multiSelect"] != true && selected.len() > 1 {
        return Err(error(400, "single choice expects one option"));
    }
    let text = a["text"].as_str().unwrap_or("");
    if text.len() > 16000 || (!text.is_empty() && !allow_text) {
        return Err(error(400, "text not allowed"));
    }
    if selected.is_empty() && text.trim().is_empty() {
        return Err(error(400, "answer cannot be empty"));
    }
    if !selected.is_empty() && !text.is_empty() {
        return Err(error(400, "select options or supply text"));
    }
    Ok(())
}

fn hash(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

impl Store {
    pub fn widget_token(
        &self,
        id: &str,
        token: &str,
        environment: &str,
        active: bool,
        registration_revision: i64,
        time: i64,
    ) -> ApiResult<Value> {
        if !(32..=256).contains(&token.len())
            || token.len() % 2 != 0
            || !token.bytes().all(|b| b.is_ascii_hexdigit())
            || !["sandbox", "production"].contains(&environment)
        {
            return Err(error(400, "invalid Widget token/environment"));
        }
        if registration_revision <= 0 {
            return Err(error(400, "registrationRevision must be a positive int64"));
        }
        let token = token.to_ascii_lowercase();
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if widget_revoked(&tx, id)? {
            return Err(error(401, "device credential revoked"));
        }
        let old:Option<(String,String,bool,i64,Option<String>,i64)>=tx.query_row("SELECT token,environment,active,version,blocked_reason,registration_revision FROM widget_tokens WHERE device=?1",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).optional()?;
        if let Some((t, e, a, _, _, revision)) = &old {
            let same = t == &token && e == environment && *a == active;
            if registration_revision < *revision {
                return Err(error(409, "registration revision stale"));
            }
            if registration_revision == *revision && !same {
                return Err(error(409, "registration revision content conflict"));
            }
            if same {
                if registration_revision > *revision {
                    tx.execute(
                        "UPDATE widget_tokens SET registration_revision=?2 WHERE device=?1",
                        params![id, registration_revision],
                    )?;
                }
                tx.commit()?;
                return Ok(json!({"registered":true}));
            }
        }
        let version = old.as_ref().map_or(1, |v| v.3 + 1);
        let blocked = old.as_ref().and_then(|(t, e, _, _, reason, _)| {
            // A request generation or Provider registration cannot retry a permanent topic/key error.
            reason
                .as_ref()
                .filter(|r| {
                    (t == &token && e == environment)
                        || !["bad_device_token", "device_unregistered"].contains(&r.as_str())
                })
                .cloned()
        });
        tx.execute("INSERT INTO widget_tokens(device,token,environment,active,version,blocked_reason,registration_revision) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(device) DO UPDATE SET token=excluded.token,environment=excluded.environment,active=excluded.active,version=excluded.version,blocked_reason=excluded.blocked_reason,registration_revision=excluded.registration_revision",params![id,token,environment,active,version,blocked,registration_revision])?;
        let snapshot = widget_snapshot(&tx)?;
        let state = if !active {
            "cancelled"
        } else if blocked.is_some() {
            "failed"
        } else {
            "pending"
        };
        tx.execute("INSERT INTO widget_updates(device,generation,acked,snapshot,state,attempts,next,error) VALUES(?1,1,0,?2,?3,0,?4,?5) ON CONFLICT(device) DO UPDATE SET generation=widget_updates.generation+1,snapshot=excluded.snapshot,state=excluded.state,attempts=0,next=excluded.next,error=excluded.error",params![id,snapshot,state,time+WIDGET_COALESCE_SECONDS,blocked])?;
        tx.commit()?;
        Ok(json!({"registered":true}))
    }
    pub fn widget_registration_revision(&self, id: &str) -> ApiResult<i64> {
        let db = self.db.lock().unwrap();
        if widget_revoked(&db, id)? {
            return Err(error(401, "device credential revoked"));
        }
        Ok(db
            .query_row(
                "SELECT registration_revision FROM widget_tokens WHERE device=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(0))
    }
    pub fn widget_batch(&self, time: i64) -> ApiResult<Vec<WidgetJob>> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        expire_widget_requests(&tx, None, time)?;
        let jobs = {
            let mut stmt=tx.prepare("SELECT t.device,t.token,t.environment,t.version,u.generation,u.attempts FROM widget_tokens t JOIN widget_updates u ON u.device=t.device WHERE t.active=1 AND t.blocked_reason IS NULL AND u.state='pending' AND u.generation>u.acked AND u.next<=?1 AND u.attempts<?2 AND NOT EXISTS(SELECT 1 FROM revoked_credentials r WHERE r.id=t.device) AND NOT EXISTS(SELECT 1 FROM device_credentials c WHERE c.id=t.device AND c.revoked<>0) ORDER BY u.next,t.device LIMIT 20")?;
            stmt.query_map(params![time, MAX_WIDGET_ATTEMPTS], |r| {
                Ok(WidgetJob {
                    device_id: r.get(0)?,
                    token: r.get(1)?,
                    environment: r.get(2)?,
                    token_version: r.get(3)?,
                    generation: r.get(4)?,
                    attempts: r.get(5)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?
        };
        tx.commit()?;
        Ok(jobs)
    }
    pub fn widget_job_authorized(&self, job: &WidgetJob, time: i64) -> ApiResult<bool> {
        let db = self.db.lock().unwrap();
        widget_job_current(&db, job, time)
    }
    pub(crate) fn widget_paired_identity(&self, id: &str) -> ApiResult<bool> {
        let db = self.db.lock().unwrap();
        Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM device_credentials c WHERE c.id=?1 AND c.revoked=0 AND NOT EXISTS(SELECT 1 FROM revoked_credentials r WHERE r.id=c.id))",[id],|r|r.get(0))?)
    }
    pub fn widget_result(
        &self,
        job: &WidgetJob,
        delivery: WidgetDelivery,
        time: i64,
    ) -> ApiResult<()> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        // Results may arrive after cooldown. Match private token/version + generation and revocation,
        // but do not require that the retry due time is still the original fetched time.
        let current:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM widget_tokens t JOIN widget_updates u ON u.device=t.device WHERE t.device=?1 AND t.token=?2 AND t.environment=?3 AND t.version=?4 AND t.active=1 AND t.blocked_reason IS NULL AND u.state='pending' AND u.generation>=?5 AND u.acked<?5 AND NOT EXISTS(SELECT 1 FROM revoked_credentials r WHERE r.id=t.device) AND NOT EXISTS(SELECT 1 FROM device_credentials c WHERE c.id=t.device AND c.revoked<>0))",params![job.device_id,job.token,job.environment,job.token_version,job.generation],|r|r.get(0))?;
        if !current {
            return Ok(());
        }
        match delivery {
            WidgetDelivery::Delivered => {
                tx.execute("UPDATE widget_updates SET acked=MAX(acked,?2),state=CASE WHEN generation<=?2 THEN 'idle' ELSE 'pending' END,attempts=CASE WHEN generation=?2 THEN 0 ELSE attempts END,error=CASE WHEN generation=?2 THEN NULL ELSE error END,next=MAX(next,?3) WHERE device=?1",params![job.device_id,job.generation,time+WIDGET_MIN_INTERVAL_SECONDS])?;
            }
            WidgetDelivery::Retry(reason) => {
                let delay = (30_i64 * (1_i64 << job.attempts.min(6))).min(1800);
                tx.execute("UPDATE widget_updates SET attempts=attempts+1,state=CASE WHEN attempts+1>=?3 THEN 'failed' ELSE 'pending' END,next=?4,error=?5 WHERE device=?1 AND generation=?2 AND attempts=?6",params![job.device_id,job.generation,MAX_WIDGET_ATTEMPTS,time+delay,reason.code(),job.attempts])?;
            }
            WidgetDelivery::Rejected(reason) => {
                tx.execute(
                    "UPDATE widget_tokens SET blocked_reason=?2 WHERE device=?1 AND version=?3",
                    params![job.device_id, reason.code(), job.token_version],
                )?;
                tx.execute(
                    "UPDATE widget_updates SET state='failed',error=?2 WHERE device=?1",
                    params![job.device_id, reason.code()],
                )?;
            }
            WidgetDelivery::Unregistered => {
                tx.execute("UPDATE widget_tokens SET blocked_reason='device_unregistered' WHERE device=?1 AND version=?2",params![job.device_id,job.token_version])?;
                tx.execute("UPDATE widget_updates SET state='failed',error='device_unregistered' WHERE device=?1",[&job.device_id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }
}
fn widget_revoked(db: &Connection, id: &str) -> ApiResult<bool> {
    Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM revoked_credentials WHERE id=?1) OR EXISTS(SELECT 1 FROM device_credentials WHERE id=?1 AND revoked<>0)",[id],|r|r.get(0))?)
}
fn widget_job_current(db: &Connection, j: &WidgetJob, time: i64) -> ApiResult<bool> {
    Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM widget_tokens t JOIN widget_updates u ON u.device=t.device WHERE t.device=?1 AND t.token=?2 AND t.environment=?3 AND t.version=?4 AND t.active=1 AND t.blocked_reason IS NULL AND u.state='pending' AND u.generation>=?5 AND u.acked<?5 AND u.next<=?6 AND u.attempts<?7 AND u.attempts=?8 AND NOT EXISTS(SELECT 1 FROM revoked_credentials r WHERE r.id=t.device) AND NOT EXISTS(SELECT 1 FROM device_credentials c WHERE c.id=t.device AND c.revoked<>0))",params![j.device_id,j.token,j.environment,j.token_version,j.generation,time,MAX_WIDGET_ATTEMPTS,j.attempts],|r|r.get(0))?)
}
fn widget_snapshot(tx: &Transaction<'_>) -> ApiResult<String> {
    let mut query = tx.prepare("SELECT id,state,expires FROM requests WHERE json_extract(json,'$.diagnosticTestId') IS NULL ORDER BY id")?;
    let rows = query.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, i64>(2)?,
        ))
    })?;
    let mut digest = Sha256::new();
    for row in rows {
        digest.update(serde_json::to_vec(&row?)?);
        digest.update([0]);
    }
    let mut progress = tx.prepare("SELECT request,json FROM reply_progress ORDER BY request")?;
    for row in progress.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        digest.update(serde_json::to_vec(&row?)?);
        digest.update([0]);
    }
    Ok(format!("{:x}", digest.finalize()))
}
fn enqueue_widget_changes(tx: &Transaction<'_>, time: i64) -> ApiResult<()> {
    let snapshot = widget_snapshot(tx)?;
    tx.execute("INSERT INTO widget_updates(device,generation,acked,snapshot,state,attempts,next,error) SELECT t.device,1,0,?1,'pending',0,?2,NULL FROM widget_tokens t WHERE t.active=1 AND t.blocked_reason IS NULL AND NOT EXISTS(SELECT 1 FROM revoked_credentials r WHERE r.id=t.device) AND NOT EXISTS(SELECT 1 FROM device_credentials c WHERE c.id=t.device AND c.revoked<>0) ON CONFLICT(device) DO UPDATE SET generation=widget_updates.generation+1,snapshot=excluded.snapshot,state='pending',attempts=0,next=CASE WHEN widget_updates.state='idle' THEN MAX(widget_updates.next,excluded.next) WHEN widget_updates.state='pending' THEN MIN(widget_updates.next,excluded.next) ELSE excluded.next END,error=NULL WHERE widget_updates.snapshot<>excluded.snapshot",params![snapshot,time+WIDGET_COALESCE_SECONDS])?;
    Ok(())
}
fn expire_widget_requests(tx: &Transaction<'_>, host: Option<&str>, time: i64) -> ApiResult<()> {
    let changed=tx.execute("UPDATE requests SET state='expired' WHERE (?1 IS NULL OR host=?1) AND expires<=?2 AND (state='pending' OR (state='submitting' AND id IN (SELECT request FROM responses WHERE claimed=0)))",params![host,time])?;
    if changed > 0 {
        enqueue_widget_changes(tx, time)?;
    }
    Ok(())
}

/// Local operator rearm only: no key, alert, registration-order or native-answer changes.
pub(crate) fn retry_widget_transaction(
    tx: &Transaction<'_>,
    id: &str,
    time: i64,
) -> ApiResult<i64> {
    let installed:bool=tx.query_row("SELECT COUNT(*)=2 FROM sqlite_schema WHERE type='table' AND name IN ('widget_tokens','widget_updates')",[],|r|r.get(0))?;
    if !installed {
        return Err(error(400, "Widget push schema not installed"));
    }
    if widget_revoked(tx, id)? {
        return Err(error(409, "paired device revoked"));
    }
    let active: Option<bool> = tx
        .query_row(
            "SELECT active FROM widget_tokens WHERE device=?1",
            [id],
            |r| r.get(0),
        )
        .optional()?;
    match active {
        None => return Err(error(404, "Widget registration not found")),
        Some(false) => return Err(error(409, "Widget configuration inactive")),
        Some(true) => {}
    }
    tx.execute(
        "UPDATE widget_tokens SET blocked_reason=NULL,version=version+1 WHERE device=?1",
        [id],
    )?;
    let snapshot = widget_snapshot(tx)?;
    tx.execute("INSERT INTO widget_updates(device,generation,acked,snapshot,state,attempts,next,error) VALUES(?1,1,0,?2,'pending',0,?3,NULL) ON CONFLICT(device) DO UPDATE SET generation=widget_updates.generation+1,snapshot=excluded.snapshot,state='pending',attempts=0,next=excluded.next,error=NULL",params![id,snapshot,time+WIDGET_COALESCE_SECONDS])?;
    Ok(tx.query_row(
        "SELECT generation FROM widget_updates WHERE device=?1",
        [id],
        |r| r.get(0),
    )?)
}
