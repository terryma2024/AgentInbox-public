//! Native, local-only operator access. Never opens via Store::open (migration/recovery).
use crate::{
    model::{ApiResult, error},
    store::{retry_widget_transaction, revoke_device_transaction},
};
use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::Path,
    time::Duration,
};

pub fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let path = args
        .first()
        .ok_or("device-admin DATABASE list|revoke|retry-widget DEVICE_ID required")?;
    let action = args
        .get(1)
        .map(String::as_str)
        .ok_or("device-admin action required")?;
    let id = match (action, args.len()) {
        ("list", 2) => None,
        ("revoke" | "retry-widget", 3) => {
            let id = &args[2];
            if id.is_empty()
                || id.len() > 128
                || !id
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"-_".contains(&c))
            {
                return Err("invalid paired device identifier".into());
            }
            Some(id.as_str())
        }
        _ => {
            return Err("device-admin DATABASE list|revoke|retry-widget DEVICE_ID required".into());
        }
    };
    let mut db = open_existing(Path::new(path), id.is_some())?;
    let result = if let Some(id) = id {
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let old = tx.query_row("SELECT revoked<>0 OR EXISTS(SELECT 1 FROM revoked_credentials WHERE id=?1) FROM device_credentials WHERE id=?1", [id], |r|r.get::<_,bool>(0)).optional()?;
        let already_revoked = old.ok_or_else(|| error(404, "paired device not found"))?;
        if action == "retry-widget" {
            if already_revoked {
                return Err(error(409, "paired device revoked").into());
            }
            let generation = retry_widget_transaction(&tx, id, crate::model::now())?;
            tx.commit()?;
            json!({"deviceId":id,"queued":true,"generation":generation})
        } else {
            revoke_device_transaction(&tx, id)?;
            tx.commit()?;
            json!({"deviceId":id,"revoked":true,"alreadyRevoked":already_revoked})
        }
    } else {
        let has_widget_tables:bool=db.query_row("SELECT COUNT(*)=2 FROM sqlite_schema WHERE type='table' AND name IN ('widget_tokens','widget_updates')",[],|r|r.get(0))?;
        let mut query = db.prepare("SELECT c.id,c.name,(c.revoked<>0 OR EXISTS(SELECT 1 FROM revoked_credentials r WHERE r.id=c.id)),COALESCE(d.active,0) FROM device_credentials c LEFT JOIN devices d ON d.id=c.id ORDER BY c.id")?;
        let rows = query.query_map([], |r| {
            let revoked = r.get::<_,bool>(2)?;
            let id=r.get::<_,String>(0)?;
            let mut metadata=json!({"deviceId":id,"name":r.get::<_,String>(1)?,"revoked":revoked,"pushActive":!revoked && r.get::<_,i64>(3)? != 0});
            if has_widget_tables {
                let widget=db.query_row("SELECT t.active,t.blocked_reason,u.generation,u.acked,u.state,u.attempts,u.error FROM widget_tokens t LEFT JOIN widget_updates u ON u.device=t.device WHERE t.device=?1",[&id],|row|Ok((row.get::<_,bool>(0)?,row.get::<_,Option<String>>(1)?,row.get::<_,Option<i64>>(2)?,row.get::<_,Option<i64>>(3)?,row.get::<_,Option<String>>(4)?,row.get::<_,Option<i64>>(5)?,row.get::<_,Option<String>>(6)?))).optional()?;
                if let Some((active,blocked,generation,acked,state,attempts,error))=widget{metadata["widgetPushActive"]=json!(active&&!revoked&&blocked.is_none());metadata["widgetGeneration"]=json!(generation);metadata["widgetAcknowledgedGeneration"]=json!(acked);metadata["widgetQueueState"]=json!(state);metadata["widgetAttempts"]=json!(attempts);metadata["widgetError"]=json!(blocked.or(error));}
            }
            Ok(metadata)
        })?;
        json!({"devices":rows.collect::<Result<Vec<Value>,_>>()?})
    };
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}

fn open_existing(path: &Path, write: bool) -> Result<Connection, Box<dyn std::error::Error>> {
    let meta = fs::symlink_metadata(path)?;
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    let uid = unsafe { geteuid() };
    if !meta.is_file()
        || meta.file_type().is_symlink()
        || meta.permissions().mode() & 0o777 != 0o600
        || (uid != 0 && meta.uid() != uid)
    {
        return Err(
            "database must be an existing owned regular file mode0600, not a symlink".into(),
        );
    }
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let parent_meta = fs::symlink_metadata(parent)?;
    if !parent_meta.is_dir()
        || parent_meta.file_type().is_symlink()
        || parent_meta.mode() & 0o022 != 0
        || (uid != 0 && parent_meta.uid() != uid)
    {
        return Err("database parent must be owned and not writable by other users".into());
    }
    let name = path.file_name().ok_or("database filename required")?;
    let canonical = fs::canonicalize(parent)?.join(name);
    let flags = (if write {
        OpenFlags::SQLITE_OPEN_READ_WRITE
    } else {
        OpenFlags::SQLITE_OPEN_READ_ONLY
    }) | OpenFlags::SQLITE_OPEN_NOFOLLOW;
    let db = Connection::open_with_flags(&canonical, flags)?;
    let after = fs::symlink_metadata(&canonical)?;
    if after.dev() != meta.dev()
        || after.ino() != meta.ino()
        || after.file_type().is_symlink()
        || after.mode() & 0o777 != 0o600
        || (uid != 0 && after.uid() != uid)
    {
        return Err("database identity/permissions changed while opening".into());
    }
    db.busy_timeout(Duration::from_secs(5))?;
    validate_schema(&db)?;
    Ok(db)
}

fn validate_schema(db: &Connection) -> ApiResult<()> {
    // Schema metadata only: never read request bodies, keys, hashes, or push tokens.
    for (table, required) in [
        ("device_credentials", &["id", "hash", "name", "revoked"][..]),
        ("revoked_credentials", &["id"][..]),
        ("devices", &["id", "token", "environment", "active"][..]),
        (
            "outbox",
            &[
                "id", "request", "device", "state", "attempts", "next", "error",
            ][..],
        ),
        (
            "requests",
            &["id", "host", "binding", "state", "expires", "json"][..],
        ),
        (
            "responses",
            &["id", "request", "device", "json", "claimed"][..],
        ),
    ] {
        let kind = db
            .query_row(
                "SELECT type FROM sqlite_schema WHERE name=?1",
                [table],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        if kind.as_deref() != Some("table") {
            return Err(error(400, "not a compatible AgentInbox database"));
        }
        let mut query = db.prepare("SELECT name,pk FROM pragma_table_info(?1)")?;
        let columns = query
            .query_map([table], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        if !required
            .iter()
            .all(|name| columns.iter().any(|(value, _)| value == name))
            || !columns.iter().any(|(name, pk)| name == "id" && *pk > 0)
        {
            return Err(error(400, "not a compatible AgentInbox database"));
        }
    }
    Ok(())
}
