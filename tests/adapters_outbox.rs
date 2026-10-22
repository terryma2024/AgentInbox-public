use agentinbox::host::{Config, flush_receipts, persist_receipt};
use serde_json::{Value, json};
use std::{fs, path::PathBuf};
fn config(state: PathBuf, url: String) -> Config {
    Config {
        host_id: "fixture-host".into(),
        relay_url: url,
        token_file: state.join("public-fixture-token"),
        state_dir: state.clone(),
        ipc_socket: state.join("ipc/hook.sock"),
        codex_socket: None,
        native_receipt_dir: None,
        daemon_pid: None,
        scopes: vec![state],
        capture_all_directories: false,
        thread_ids: vec![],
        excluded_session_ids: vec![],
        capture_loaded_native: false,
        daemon_peer_pid: None,
        request_ttl: 60,
        adoption_marker: None,
    }
}
#[test]
fn receipt_survives_disconnect_then_process_restart_and_reconciles_local_race() {
    let root =
        std::env::temp_dir().join(format!("agentinbox-outbox-test-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&root).unwrap();
    let payload = json!({"hostId":"fixture-host","requestId":"request-1","responseId":null,"state":"handledLocally","evidence":{"nativeResolvedBeforeDispatch":true}});
    let path = persist_receipt(&root, &payload).unwrap();
    let offline = config(root.clone(), "http://127.0.0.1:0".into());
    assert_eq!(flush_receipts(&offline, "public-non-secret-fixture"), 0);
    assert!(path.exists());
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let address = server.server_addr().to_ip().unwrap();
    let worker = std::thread::spawn(move || {
        let q = server
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap()
            .unwrap();
        assert_eq!(q.url(), "/v1/requests/request-1");
        q.respond(tiny_http::Response::from_string(json!({"hostId":"fixture-host","requestId":"request-1","responseId":"remote-before-host-claim","state":"submitting"}).to_string())).unwrap();
        let mut q = server
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap()
            .unwrap();
        assert_eq!(q.url(), "/v1/host/receipt");
        let body: Value = serde_json::from_reader(q.as_reader()).unwrap();
        assert_eq!(body["responseId"], "remote-before-host-claim");
        assert_eq!(body["state"], "handledLocally");
        q.respond(tiny_http::Response::from_string(
            json!({"state":"handledLocally"}).to_string(),
        ))
        .unwrap();
    });
    // A fresh Config models restarting the host; only the saved receipt is sent, no engine callback exists.
    let restarted = config(root.clone(), format!("http://{address}"));
    assert_eq!(flush_receipts(&restarted, "public-non-secret-fixture"), 1);
    assert!(!path.exists());
    worker.join().unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn one_hundred_terminal_conflicts_do_not_starve_the_next_receipt() {
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    let root = std::env::temp_dir().join(format!("ainb-outbox-many-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&root).unwrap();
    for n in 0..100 {
        persist_receipt(&root,&json!({"hostId":"fixture-host","requestId":format!("closed-{n}"),"responseId":"r","state":"unknown","evidence":{"timeout":true}})).unwrap();
    }
    let good=persist_receipt(&root,&json!({"hostId":"fixture-host","requestId":"the-next-valid","responseId":"r","state":"unknown","evidence":{"timeout":true}})).unwrap();
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}", server.server_addr().to_ip().unwrap());
    let stopped = Arc::new(AtomicBool::new(false));
    let stopper = stopped.clone();
    let worker = std::thread::spawn(move || {
        while !stopper.load(Ordering::SeqCst) {
            if let Some(q) = server
                .recv_timeout(std::time::Duration::from_millis(100))
                .unwrap()
            {
                let state = if q.url().contains("the-next-valid") {
                    "submitting"
                } else {
                    "adopted"
                };
                let result = if q.method().as_str() == "POST" {
                    json!({"state":"unknown"})
                } else {
                    json!({"hostId":"fixture-host","responseId":"r","state":state})
                };
                q.respond(tiny_http::Response::from_string(result.to_string()))
                    .unwrap();
            }
        }
    });
    assert_eq!(
        flush_receipts(&config(root.clone(), url), "public-test-fixture"),
        101
    );
    assert!(!good.exists());
    assert_eq!(
        fs::read_dir(root.join("receipt-conflicts"))
            .unwrap()
            .count(),
        100
    );
    stopped.store(true, Ordering::SeqCst);
    worker.join().unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn startup_reconciliation_retries_and_persists_before_a_failed_receipt() {
    let root = std::env::temp_dir().join(format!("ainb-startup-gate-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&root).unwrap();
    assert!(
        agentinbox::host::reconcile_startup(
            &config(root.clone(), "http://127.0.0.1:0".into()),
            "public-fixture"
        )
        .is_err()
    );
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}", server.server_addr().to_ip().unwrap());
    let worker = std::thread::spawn(move || {
        for attempt in 0..2 {
            for phase in 0..3 {
                let q = server
                    .recv_timeout(std::time::Duration::from_secs(5))
                    .unwrap()
                    .unwrap();
                let row = json!({"hostId":"fixture-host","requestId":"stale-original-callback","responseId":null,"state":"pending","engine":"codex"});
                let (status, result) = match phase {
                    0 => {
                        assert_eq!(q.url(), "/v1/host/requests");
                        (200, json!({"requests":[row]}))
                    }
                    1 => {
                        assert_eq!(q.url(), "/v1/requests/stale-original-callback");
                        (200, row)
                    }
                    _ => {
                        assert_eq!(q.url(), "/v1/host/receipt");
                        if attempt == 0 {
                            (503, json!({"error":"fixture disconnect"}))
                        } else {
                            (200, json!({"state":"invalidated"}))
                        }
                    }
                };
                q.respond(
                    tiny_http::Response::from_string(result.to_string()).with_status_code(status),
                )
                .unwrap();
            }
        }
    });
    let c = config(root.clone(), url);
    assert!(agentinbox::host::reconcile_startup(&c, "public-fixture").is_err());
    assert!(
        root.join("receipt-outbox/stale-original-callback-invalidated.json")
            .exists()
    );
    assert!(agentinbox::host::reconcile_startup(&c, "public-fixture").is_ok());
    assert!(
        !root
            .join("receipt-outbox/stale-original-callback-invalidated.json")
            .exists()
    );
    worker.join().unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn same_state_proof_conflict_is_archived_instead_of_retried_forever() {
    let root = std::env::temp_dir().join(format!("ainb-proof-conflict-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&root).unwrap();
    let payload = json!({"hostId":"fixture-host","requestId":"original","responseId":"answer","state":"adopted","evidence":{"exactStructuredAnswer":true},"replyProgress":{"schemaVersion":1,"requestId":"original","responseId":"answer","bindingDigest":"a".repeat(64),"received":{"proofId":"received-1","kind":"codex.function_call_output","position":3,"sourceDigest":"b".repeat(64)},"continued":null,"continuationObservation":"awaiting"}});
    let path = persist_receipt(&root, &payload).unwrap();
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}", server.server_addr().to_ip().unwrap());
    let worker = std::thread::spawn(move || {
        for phase in 0..3 {
            let q = server
                .recv_timeout(std::time::Duration::from_secs(3))
                .unwrap()
                .unwrap();
            let (status, body) = match phase {
                0 => {
                    assert_eq!(q.url(), "/v1/requests/original");
                    (
                        200,
                        json!({"hostId":"fixture-host","requestId":"original","responseId":"answer","state":"adopted","bindingDigest":"a".repeat(64)}),
                    )
                }
                1 => {
                    assert_eq!(q.url(), "/v1/capabilities");
                    (
                        200,
                        json!({"replyProgressVersion":1,"bindingDigestVersion":1}),
                    )
                }
                _ => {
                    assert_eq!(q.url(), "/v1/host/receipt");
                    (409, json!({"error":"conflicting native proof"}))
                }
            };
            q.respond(tiny_http::Response::from_string(body.to_string()).with_status_code(status))
                .unwrap();
        }
    });
    assert_eq!(
        flush_receipts(&config(root.clone(), url), "public-test-fixture"),
        1
    );
    assert!(!path.exists());
    assert_eq!(
        fs::read_dir(root.join("receipt-conflicts"))
            .unwrap()
            .count(),
        1
    );
    worker.join().unwrap();
    fs::remove_dir_all(root).unwrap();
}
