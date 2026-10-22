//! Opt-in native arbitration receipts. An arbitration receipt must still be paired
//! with the original tool output; it is not itself proof of tool consumption.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    pub schema_version: u32,
    pub native_pid: u32,
    pub native_instance_id: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Dispatch {
    pub schema_version: u32,
    pub dispatch_id: String,
    pub binding_digest: String,
    pub native_instance_id: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub directory: PathBuf,
    pub manifest: Manifest,
}
impl Source {
    pub fn connect(directory: &Path, peer_pid: u32) -> Result<Self, String> {
        let manifest: Manifest = serde_json::from_value(read_private(directory, "manifest.json")?)
            .map_err(|_| "invalid native receipt manifest")?;
        if manifest.schema_version != 1
            || manifest.native_pid != peer_pid
            || peer_pid == 0
            || !canonical_uuid(&manifest.native_instance_id)
        {
            return Err("native receipt process or version mismatch".into());
        }
        Ok(Self {
            directory: fs::canonicalize(directory)
                .map_err(|_| "native receipt directory unavailable")?,
            manifest,
        })
    }
    pub fn dispatch(&self, q: &Value) -> Dispatch {
        Dispatch {
            schema_version: 1,
            dispatch_id: uuid::Uuid::new_v4().to_string(),
            binding_digest: crate::reply_progress::binding_digest(q),
            native_instance_id: self.manifest.native_instance_id.clone(),
        }
    }
    pub fn verify(
        &self,
        dispatch: &Dispatch,
        q: &Value,
        callback: &Value,
        answer: &Value,
    ) -> Option<String> {
        self.verify_record(dispatch, q, callback, answer, true)
    }
    fn verify_record(
        &self,
        dispatch: &Dispatch,
        q: &Value,
        callback: &Value,
        answer: &Value,
        current: bool,
    ) -> Option<String> {
        if q["engine"] != "codex"
            || !self.directory.is_absolute()
            || fs::canonicalize(&self.directory).ok()? != self.directory
            || dispatch.schema_version != 1
            || !canonical_uuid(&dispatch.dispatch_id)
            || dispatch.native_instance_id != self.manifest.native_instance_id
            || dispatch.binding_digest != crate::reply_progress::binding_digest(q)
            || self.manifest.schema_version != 1
            || self.manifest.native_pid == 0
            || !canonical_uuid(&self.manifest.native_instance_id)
            || (current
                && Self::connect(&self.directory, self.manifest.native_pid)
                    .ok()?
                    .manifest
                    != self.manifest)
        {
            return None;
        }
        let record = read_private(
            &self.directory,
            &format!("dispatch-{}.json", dispatch.dispatch_id),
        )
        .ok()?;
        let expected = crate::adapters::codex::response(callback, q, answer).ok()?;
        if record["schemaVersion"] != 1
            || record["nativePid"] != self.manifest.native_pid
            || record["nativeInstanceId"] != self.manifest.native_instance_id
            || record["dispatchId"] != dispatch.dispatch_id
            || record["bindingDigest"] != dispatch.binding_digest
            || record["callback"] != *callback
            || record["result"] != expected["result"]
        {
            return None;
        }
        Some(format!(
            "{:x}",
            Sha256::digest(record.to_string().as_bytes())
        ))
    }
    pub fn observe(
        &self,
        dispatch: &Dispatch,
        q: &Value,
        callback: &Value,
        answer: &Value,
        text: &str,
        boundary: &crate::reply_evidence::DispatchBoundary,
    ) -> crate::reply_evidence::Observation {
        let Some(source) = self.verify(dispatch, q, callback, answer) else {
            return Default::default();
        };
        bind_observation(
            source,
            crate::reply_evidence::observe(q, callback, answer, text, boundary),
        )
    }
    /// Read-only reconciliation pinned to the fsynced dispatch, not a new live process.
    pub(crate) fn observe_saved(
        &self,
        dispatch: &Dispatch,
        q: &Value,
        callback: &Value,
        answer: &Value,
        text: &str,
        boundary: &crate::reply_evidence::DispatchBoundary,
    ) -> crate::reply_evidence::Observation {
        let Some(source) = self.verify_record(dispatch, q, callback, answer, false) else {
            return Default::default();
        };
        bind_observation(
            source,
            crate::reply_evidence::observe(q, callback, answer, text, boundary),
        )
    }
}
fn bind_observation(
    source: String,
    mut observation: crate::reply_evidence::Observation,
) -> crate::reply_evidence::Observation {
    let Some(received) = observation.received.as_mut() else {
        return observation;
    };
    for proof in [Some(&mut *received), observation.continued.as_mut()]
        .into_iter()
        .flatten()
    {
        let digest = format!(
            "{:x}",
            Sha256::digest(format!("{source}:{}", proof["sourceDigest"]))
        );
        proof["sourceDigest"] = serde_json::json!(digest);
        proof["proofId"] = serde_json::json!(format!("proof-{}-{digest}", proof["position"]));
    }
    if let Some(continued) = observation.continued.as_mut() {
        continued["receivedProofId"] = received["proofId"].clone();
    }
    observation
}
fn canonical_uuid(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok_and(|u| u.to_string() == value)
}
pub(crate) fn read_private(directory: &Path, name: &str) -> Result<Value, String> {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    let uid = unsafe { geteuid() };
    let private = |m: &fs::Metadata| m.uid() == uid && m.mode() & 0o077 == 0;
    let d = fs::symlink_metadata(directory).map_err(|_| "native receipt directory unavailable")?;
    if !d.is_dir() || d.file_type().is_symlink() || !private(&d) {
        return Err("native receipt directory must be private and owned".into());
    }
    let path = directory.join(name);
    let before = fs::symlink_metadata(&path).map_err(|_| "native receipt unavailable")?;
    if !before.is_file()
        || before.file_type().is_symlink()
        || !private(&before)
        || before.len() > 1_048_576
    {
        return Err("native receipt must be a bounded private regular file".into());
    }
    #[cfg(target_os = "macos")]
    let nofollow = 0x100;
    #[cfg(not(target_os = "macos"))]
    let nofollow = 0x20000;
    let f = fs::OpenOptions::new()
        .read(true)
        .custom_flags(nofollow)
        .open(&path)
        .map_err(|_| "native receipt open refused")?;
    let opened = f
        .metadata()
        .map_err(|_| "native receipt metadata unavailable")?;
    if opened.dev() != before.dev() || opened.ino() != before.ino() || !private(&opened) {
        return Err("native receipt changed during open".into());
    }
    let mut bytes = Vec::new();
    f.take(1_048_577)
        .read_to_end(&mut bytes)
        .map_err(|_| "native receipt read failed")?;
    if bytes.len() > 1_048_576 {
        return Err("native receipt exceeds limit".into());
    }
    serde_json::from_slice(&bytes).map_err(|_| "native receipt JSON invalid".into())
}
