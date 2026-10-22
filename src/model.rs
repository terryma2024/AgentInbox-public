use serde_json::Value;
pub type ApiResult<T> = Result<T, ApiError>;
#[derive(Debug)]
pub struct ApiError {
    pub status: u16,
    pub message: String,
}
impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.status, self.message)
    }
}
impl std::error::Error for ApiError {}
impl From<rusqlite::Error> for ApiError {
    fn from(_: rusqlite::Error) -> Self {
        error(500, "database operation failed")
    }
}
impl From<serde_json::Error> for ApiError {
    fn from(_: serde_json::Error) -> Self {
        error(400, "invalid JSON")
    }
}
pub fn error(status: u16, message: &str) -> ApiError {
    ApiError {
        status,
        message: message.into(),
    }
}
pub fn string<'a>(v: &'a Value, key: &str) -> ApiResult<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| error(400, &format!("missing {key}")))
}
pub fn identifier(v: &Value, key: &str) -> ApiResult<String> {
    let s = string(v, key)?;
    if s.len() > 256
        || !s
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_: .".contains(&b))
        || s.contains(' ')
    {
        return Err(error(400, "invalid identifier"));
    }
    Ok(s.into())
}
pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
