use serde_json::Value;
fn call(
    base: &str,
    token: &str,
    path: &str,
    body: Option<&Value>,
    timeout: std::time::Duration,
) -> Result<Value, String> {
    if !base.starts_with("http://") && !base.starts_with("https://") {
        return Err("unsupported API URL".into());
    }
    // AgentInbox relay traffic stays on the local/Tailscale route, never an environment proxy.
    let c = reqwest::blocking::Client::builder()
        .no_proxy()
        .timeout(timeout)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "HTTP client initialization failed")?;
    let url = format!("{}{}", base.trim_end_matches('/'), path);
    let request = if let Some(body) = body {
        c.post(&url).json(body)
    } else {
        c.get(&url)
    };
    let result = request
        .header("Connection", "close")
        .bearer_auth(token)
        .send()
        .map_err(|_| "relay connection failed".to_string())?;
    let status = result.status();
    let payload: Value = result
        .json()
        .map_err(|_| "invalid relay JSON".to_string())?;
    if !status.is_success() {
        return Err(format!(
            "HTTP {}: {}",
            status.as_u16(),
            payload["error"].as_str().unwrap_or("request failed")
        ));
    }
    Ok(payload)
}
pub fn get_json(base: &str, token: &str, path: &str) -> Result<Value, String> {
    call(base, token, path, None, std::time::Duration::from_secs(15))
}
pub fn post_json(base: &str, token: &str, path: &str, body: &Value) -> Result<Value, String> {
    call(
        base,
        token,
        path,
        Some(body),
        std::time::Duration::from_secs(15),
    )
}

pub(crate) fn get_json_bounded(
    base: &str,
    token: &str,
    path: &str,
    timeout: std::time::Duration,
) -> Result<Value, String> {
    call(base, token, path, None, timeout)
}
