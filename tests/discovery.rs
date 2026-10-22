use agentinbox::discovery::{DiscoveryInfo, bind, serve_one, start_from_args};
use std::time::Duration;

fn info() -> DiscoveryInfo {
    DiscoveryInfo::new(
        "stable-host",
        "fixture-host",
        "https://relay.example.com:8443",
    )
    .unwrap()
}

#[test]
fn discovery_only_allows_private_listener_and_safe_relay_origin() {
    assert!(bind("0.0.0.0:0").is_err());
    assert!(bind("192.168.1.1:0").is_err());
    for url in [
        "http://example.com",
        "https://user:secret@example.com",
        "file:///tmp",
        "https://example.com/path",
        "http://127.0.0.1:8787",
    ] {
        assert!(DiscoveryInfo::new("host", "name", url).is_err(), "{url}");
    }
    assert!(DiscoveryInfo::new("host", "name", "http://100.100.1.2:8787").is_ok());
}

#[test]
fn metadata_is_read_only_and_never_exposes_credentials_or_tasks() {
    let server = bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", server.server_addr());
    let worker = std::thread::spawn(move || {
        for _ in 0..3 {
            serve_one(&server, &info()).unwrap();
        }
    });
    let client = reqwest::blocking::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(3))
        .build()
        .unwrap();
    let response = client.get(format!("{base}/v1/discovery")).send().unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()["cache-control"], "no-store");
    let value: serde_json::Value = response.json().unwrap();
    assert_eq!(value["product"], "agentinbox");
    assert_eq!(value["hostId"], "stable-host");
    assert_eq!(value["relayURL"], "https://relay.example.com:8443");
    assert_eq!(value.as_object().unwrap().len(), 8);
    assert!(!value["version"].as_str().unwrap().is_empty());
    assert_eq!(
        client
            .post(format!("{base}/v1/discovery"))
            .send()
            .unwrap()
            .status(),
        405
    );
    assert_eq!(
        client
            .get(format!("{base}/v1/requests"))
            .send()
            .unwrap()
            .status(),
        404
    );
    worker.join().unwrap();
}

#[test]
fn discovery_is_opt_in_and_rejects_incomplete_or_duplicate_options() {
    assert!(start_from_args(&[], "host").unwrap().is_none());
    for args in [
        vec!["--discovery-listen"],
        vec!["--discovery-relay-url"],
        vec!["--discovery-listen", "127.0.0.1:0"],
        vec![
            "--discovery-listen",
            "127.0.0.1:0",
            "--discovery-relay-url",
            "https://relay.example.com",
            "--discovery-listen",
            "127.0.0.1:1",
        ],
    ] {
        let args = args.into_iter().map(String::from).collect::<Vec<_>>();
        assert!(start_from_args(&args, "host").is_err(), "{args:?}");
    }
}
