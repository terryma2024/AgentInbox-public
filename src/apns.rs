use crate::widget_push::{WidgetDelivery, WidgetFailure, WidgetJob};
use crate::{model::now, store::Store};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use p256::ecdsa::{Signature, SigningKey, signature::Signer};
use p256::pkcs8::DecodePrivateKey;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    io::Read,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub team_id: String,
    pub key_id: String,
    pub topic: String,
    pub private_key_path: String,
}
fn jwt(c: &Config, issued_at: i64) -> Result<String, Box<dyn std::error::Error>> {
    let header = URL_SAFE_NO_PAD.encode(json!({"alg":"ES256","kid":c.key_id}).to_string());
    let claims = URL_SAFE_NO_PAD.encode(json!({"iss":c.team_id,"iat":issued_at}).to_string());
    let message = format!("{header}.{claims}");
    let pem = std::fs::read_to_string(&c.private_key_path)?;
    let key = SigningKey::from_pkcs8_pem(&pem)?;
    let signature: Signature = key.sign(message.as_bytes());
    Ok(format!(
        "{message}.{}",
        URL_SAFE_NO_PAD.encode(signature.to_bytes())
    ))
}
fn provider_token(
    cache: &mut Option<(i64, String)>,
    c: &Config,
    time: i64,
) -> Result<String, Box<dyn std::error::Error>> {
    if let Some((issued, token)) = cache.as_ref() {
        if time >= *issued && time - issued < 3000 {
            return Ok(token.clone());
        }
    }
    let token = jwt(c, time)?;
    *cache = Some((time, token.clone()));
    Ok(token)
}

type SharedProviderCache = Arc<Mutex<Option<(i64, String)>>>;
fn cached_provider_token(
    cache: &SharedProviderCache,
    c: &Config,
    time: i64,
) -> Result<String, Box<dyn std::error::Error>> {
    let mut cache = cache.lock().map_err(|_| "provider cache unavailable")?;
    provider_token(&mut cache, c, time)
}
pub fn worker(store: Arc<Store>, c: Config, config_path: PathBuf) {
    let provider_cache: SharedProviderCache = Arc::new(Mutex::new(None));
    let widget_store = store.clone();
    let widget_config = c.clone();
    let widget_cache = provider_cache.clone();
    // Separate HTTP/2 pool for the new widgets topic and independent network progress.
    std::thread::spawn(move || {
        widget_worker(widget_store, widget_config, config_path, widget_cache)
    });
    let client = match reqwest::blocking::Client::builder()
        .http2_prior_knowledge()
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(c) => c,
        Err(_) => return,
    };
    loop {
        if let Ok(batch) = store.push_batch(now()) {
            for p in batch {
                let id = p["id"].as_i64().unwrap_or(0);
                let token = match cached_provider_token(&provider_cache, &c, now()) {
                    Ok(t) => t,
                    Err(_) => {
                        let _ = store.push_result(id, false, false, now());
                        continue;
                    }
                };
                let endpoint = if p["environment"] == "sandbox" {
                    "https://api.sandbox.push.apple.com"
                } else {
                    "https://api.push.apple.com"
                };
                let payload = notification_payload(&p);
                let request = client
                    .post(format!(
                        "{endpoint}/3/device/{}",
                        p["token"].as_str().unwrap_or("")
                    ))
                    .bearer_auth(token)
                    .header("apns-topic", &c.topic)
                    .header("apns-push-type", "alert")
                    .header("apns-priority", "10")
                    .header(
                        "apns-collapse-id",
                        format!(
                            "{:x}",
                            Sha256::digest(p["requestId"].as_str().unwrap_or("").as_bytes())
                        ),
                    )
                    .header(
                        "apns-expiration",
                        p["expiresAt"].as_i64().unwrap_or(0).to_string(),
                    )
                    .json(&payload);
                // JWT/file work may outlive revocation. Recheck the live DB after
                // building the request and immediately before starting HTTP.
                if !store.push_job_authorized(id, now()).unwrap_or(false) {
                    continue;
                }
                let r = request.send();
                let (ok, permanent) = match r {
                    Ok(r) => {
                        if r.status().as_u16() == 410 {
                            let _ = store.invalidate_push_token(p["token"].as_str().unwrap_or(""));
                        }
                        (
                            r.status().is_success(),
                            matches!(r.status().as_u16(), 400 | 403 | 410),
                        )
                    }
                    Err(_) => (false, false),
                };
                let _ = store.push_result(id, ok, permanent, now());
            }
        }
        std::thread::sleep(Duration::from_secs(5));
    }
}

fn notification_payload(p: &Value) -> Value {
    let mut payload = json!({"aps":{"alert":{"title":"Agent 决策收件箱","body":"有一项任务等待你的回复"},"sound":"default"},"requestId":p["requestId"]});
    if let Some(test) = p["diagnosticTestId"].as_str() {
        payload["diagnosticTestId"] = json!(test);
    }
    payload
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn diagnostic_push_has_exact_test_route_without_contents() {
        let payload = notification_payload(
            &json!({"requestId":"fixture-request","diagnosticTestId":"fixture-test","body":"fixture-sensitive-text"}),
        );
        assert_eq!(payload["diagnosticTestId"], "fixture-test");
        assert!(!payload.to_string().contains("fixture-sensitive-text"));
    }
    #[test]
    fn payload_does_not_include_request_contents() {
        let p = json!({"requestId":"opaque","body":"secret-question","options":["password"],"native":"callback","token":"private-device-token"});
        let payload = notification_payload(&p).to_string();
        for secret in [
            "secret-question",
            "password",
            "callback",
            "private-device-token",
        ] {
            assert!(!payload.contains(secret))
        }
        assert!(payload.contains("opaque"));
    }
    #[test]
    fn provider_jwt_is_reused_and_refreshed_before_apple_expiry() {
        use p256::pkcs8::{EncodePrivateKey, LineEnding};
        let dir = std::env::temp_dir().join(format!(
            "agentinbox-public-key-fixture-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&dir).unwrap();
        // Deterministic public test fixture; not an Apple-registered credential.
        let key = SigningKey::from_slice(&[7u8; 32]).unwrap();
        let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap();
        let file = dir.join("public-fixture.p8");
        std::fs::write(&file, pem.as_bytes()).unwrap();
        let c = Config {
            team_id: "FIXTURE".into(),
            key_id: "FIXTURE".into(),
            topic: "test.invalid".into(),
            private_key_path: file.to_str().unwrap().into(),
        };
        let mut cache = None;
        let first = provider_token(&mut cache, &c, 10_000).unwrap();
        std::fs::remove_file(&file).unwrap();
        let second = provider_token(&mut cache, &c, 10_001);
        let reuse = second.as_ref().is_ok_and(|v| v == &first);
        std::fs::write(&file, pem.as_bytes()).unwrap();
        let fresh = provider_token(&mut cache, &c, 13_001).unwrap();
        let parts: Vec<_> = fresh.split('.').collect();
        let claims: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(
            reuse,
            "short-interval push must reuse JWT without re-reading key"
        );
        assert_ne!(fresh, first);
        assert_eq!(claims["iat"], 13_001);
    }
}

#[cfg(test)]
mod widget_tests {
    use super::*;
    use crate::widget_push::{WidgetDelivery, WidgetFailure, WidgetJob};
    #[test]
    fn widgets_request_has_derived_topic_and_only_content_changed_payload() {
        let c = Config {
            team_id: "FIXTURE".into(),
            key_id: "FIXTURE".into(),
            topic: "dev.fixture.app".into(),
            private_key_path: "unused".into(),
        };
        let job = WidgetJob {
            device_id: "d".into(),
            token: "a".repeat(64),
            environment: "sandbox".into(),
            token_version: 1,
            generation: 2,
            attempts: 0,
        };
        let request = widget_request(
            &reqwest::blocking::Client::new(),
            &c,
            &job,
            "public-provider-fixture",
            1000,
        )
        .build()
        .unwrap();
        assert_eq!(request.headers()["apns-push-type"], "widgets");
        assert_eq!(
            request.headers()["apns-topic"],
            "dev.fixture.app.push-type.widgets"
        );
        assert_eq!(request.headers()["apns-expiration"], "1300");
        assert_eq!(request.headers()["apns-collapse-id"].as_bytes().len(), 64);
        let payload: Value =
            serde_json::from_slice(request.body().unwrap().as_bytes().unwrap()).unwrap();
        assert_eq!(payload, json!({"aps":{"content-changed":true}}));
        assert!(!payload.to_string().contains(&job.token));
    }
    #[test]
    fn apns_widget_errors_are_allowlisted_and_permanent_topic_rejections_do_not_retry() {
        for (reason, expected) in [
            ("TopicDisallowed", WidgetFailure::TopicDisallowed),
            (
                "DeviceTokenNotForTopic",
                WidgetFailure::DeviceTokenNotForTopic,
            ),
            ("BadTopic", WidgetFailure::BadTopic),
            ("BadDeviceToken", WidgetFailure::BadDeviceToken),
            ("InvalidProviderToken", WidgetFailure::InvalidProviderToken),
            ("ExpiredProviderToken", WidgetFailure::ExpiredProviderToken),
        ] {
            assert_eq!(
                widget_delivery(403, Some(reason)),
                WidgetDelivery::Rejected(expected)
            );
        }
        assert_eq!(widget_delivery(200, None), WidgetDelivery::Delivered);
        assert_eq!(
            widget_delivery(410, Some("Unregistered")),
            WidgetDelivery::Unregistered
        );
        assert_eq!(
            widget_delivery(429, Some("TooManyRequests")),
            WidgetDelivery::Retry(WidgetFailure::RateLimited)
        );
        assert_eq!(
            widget_delivery(503, None),
            WidgetDelivery::Retry(WidgetFailure::ServerError)
        );
        assert_eq!(
            widget_delivery(400, Some("untrusted-token-secret")),
            WidgetDelivery::Rejected(WidgetFailure::Rejected)
        );
    }
}

fn widget_request(
    client: &reqwest::blocking::Client,
    c: &Config,
    job: &WidgetJob,
    provider: &str,
    time: i64,
) -> reqwest::blocking::RequestBuilder {
    let endpoint = if job.environment == "sandbox" {
        "https://api.sandbox.push.apple.com"
    } else {
        "https://api.push.apple.com"
    };
    client
        .post(format!("{endpoint}/3/device/{}", job.token))
        .bearer_auth(provider)
        .header("apns-topic", format!("{}.push-type.widgets", c.topic))
        .header("apns-push-type", "widgets")
        .header("apns-priority", "5")
        .header(
            "apns-collapse-id",
            format!("{:x}", Sha256::digest(job.device_id.as_bytes())),
        )
        .header("apns-expiration", (time + 300).to_string())
        .json(&json!({"aps":{"content-changed":true}}))
}
fn widget_delivery(status: u16, reason: Option<&str>) -> WidgetDelivery {
    if status == 200 {
        return WidgetDelivery::Delivered;
    }
    if status == 410 {
        return WidgetDelivery::Unregistered;
    }
    if status == 429 {
        return WidgetDelivery::Retry(WidgetFailure::RateLimited);
    }
    if status >= 500 {
        return WidgetDelivery::Retry(WidgetFailure::ServerError);
    }
    let failure = match reason {
        Some("BadDeviceToken") => WidgetFailure::BadDeviceToken,
        Some("BadTopic") => WidgetFailure::BadTopic,
        Some("TopicDisallowed") => WidgetFailure::TopicDisallowed,
        Some("DeviceTokenNotForTopic") => WidgetFailure::DeviceTokenNotForTopic,
        Some("InvalidProviderToken") => WidgetFailure::InvalidProviderToken,
        Some("ExpiredProviderToken") => WidgetFailure::ExpiredProviderToken,
        _ if status == 403 => WidgetFailure::Forbidden,
        _ => WidgetFailure::Rejected,
    };
    WidgetDelivery::Rejected(failure)
}
fn widget_worker(
    store: Arc<Store>,
    c: Config,
    config_path: PathBuf,
    provider_cache: SharedProviderCache,
) {
    let client = match reqwest::blocking::Client::builder()
        .http2_prior_knowledge()
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(c) => c,
        Err(_) => return,
    };
    loop {
        if let Ok(batch) = store.widget_batch(now()) {
            for job in batch {
                let provider = match cached_provider_token(&provider_cache, &c, now()) {
                    Ok(t) => t,
                    Err(_) => {
                        let _ = store.widget_result(
                            &job,
                            WidgetDelivery::Retry(WidgetFailure::CredentialsUnavailable),
                            now(),
                        );
                        continue;
                    }
                };
                let request = widget_request(&client, &c, &job, &provider, now());
                // JWT/IO may outlive rotation or revocation. Never start HTTP for the old snapshot.
                let paired = store
                    .widget_paired_identity(&job.device_id)
                    .unwrap_or(false);
                if !crate::relay::widget_device_identity_enabled(
                    &config_path,
                    &job.device_id,
                    paired,
                ) || !store.widget_job_authorized(&job, now()).unwrap_or(false)
                {
                    continue;
                }
                let delivery = match request.send() {
                    Ok(response) => {
                        let status = response.status().as_u16();
                        let mut body = String::new();
                        let _ = response.take(2048).read_to_string(&mut body);
                        let data: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
                        widget_delivery(status, data["reason"].as_str())
                    }
                    Err(_) => WidgetDelivery::Retry(WidgetFailure::Transport),
                };
                // Persist only allowlisted codes. Raw APNs bodies, URLs/tokens and reqwest errors are discarded.
                let _ = store.widget_result(&job, delivery, now());
            }
        }
        std::thread::sleep(Duration::from_secs(5));
    }
}
