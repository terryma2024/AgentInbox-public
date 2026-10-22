use agentinbox::relay::{Config, Credential, authorize};
#[test]
fn role_revoke_host_binding() {
    let mut c = Config::default();
    c.credentials = vec![
        Credential {
            id: "d".into(),
            token: "test-device-token-only".into(),
            role: "device".into(),
            host_id: None,
            revoked: false,
        },
        Credential {
            id: "h".into(),
            token: "test-host-token-only".into(),
            role: "host".into(),
            host_id: Some("h".into()),
            revoked: false,
        },
    ];
    assert!(authorize(&c, "Bearer test-device-token-only", true).is_err());
    assert!(authorize(&c, "Bearer test-host-token-only", true).is_ok());
    assert!(authorize(&c, "Bearer wrong", false).is_err());
    c.credentials[0].revoked = true;
    assert!(authorize(&c, "Bearer test-device-token-only", false).is_err());
}
