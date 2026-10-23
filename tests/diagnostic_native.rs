use agentinbox::diagnostic_native::Probe;
use serde_json::json;
use std::time::Duration;

#[test]
fn native_test_uses_private_cwd_loopback_provider_and_fixed_tool_events() {
    let dir = std::env::temp_dir().join(format!("diagnostic-native-{}", uuid::Uuid::new_v4()));
    let probe = Probe::start(&dir, "fixture-test", agentinbox::model::now() + 10).unwrap();
    let params = probe.thread_params();
    assert_eq!(params["sandbox"], "read-only");
    assert_eq!(params["approvalPolicy"], "never");
    let url = params["config"]["model_providers.agentinbox_diagnostic"]["base_url"]
        .as_str()
        .unwrap();
    assert!(url.starts_with("http://127.0.0.1:"));
    let client = reqwest::blocking::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(3))
        .build()
        .unwrap();
    let events = client
        .post(format!("{url}/responses"))
        .json(&json!({"input":[]}))
        .send()
        .unwrap()
        .text()
        .unwrap();
    assert!(events.contains("request_user_input"));
    assert!(!events.contains("function_call_output"));
    assert!(!events.contains("received"));
    let next = client
        .post(format!("{url}/responses"))
        .json(&json!({"input":[]}))
        .send()
        .unwrap()
        .text()
        .unwrap();
    assert!(next.contains("Diagnostic continued."));
    drop(probe);
    std::fs::remove_dir_all(dir).unwrap();
}
