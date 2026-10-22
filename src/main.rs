use agentinbox::{client, hook, host, relay};
fn main() {
    if let Err(e) = run() {
        eprintln!("agentinbox: {e}");
        std::process::exit(1);
    }
}
fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(role) = args.first() else {
        return Err("usage: agentinbox relay|host|hook|hostctl|client|device-admin ...".into());
    };
    match role.as_str() {
        "cancel-fixture" => agentinbox::adapters::codex::cancel_fixture(&args[1..]),
        "inspect-codex" => agentinbox::adapters::codex::inspect(&args[1..]),
        "device-admin" => agentinbox::device_admin::run(&args[1..]),
        "relay" => relay::run(&args[1..]),
        "host" => host::run(&args[1..]),
        "hook" => hook::run(&args[1..]),
        "hostctl" => hook::control(&args[1..]),
        "client" => {
            if args.len() < 5 {
                return Err("client BASE_URL TOKEN_FILE GET|POST PATH [JSON_FILE]".into());
            }
            let token = std::fs::read_to_string(&args[2])?;
            let v = if args[3] == "GET" {
                client::get_json(&args[1], token.trim(), &args[4])
            } else if args[3] == "POST" {
                let body = serde_json::from_str(&std::fs::read_to_string(
                    args.get(5).ok_or("JSON file required")?,
                )?)?;
                client::post_json(&args[1], token.trim(), &args[4], &body)
            } else {
                return Err("GET or POST required".into());
            };
            println!(
                "{}",
                serde_json::to_string_pretty(&v.map_err(std::io::Error::other)?)?
            );
            Ok(())
        }
        _ => Err("unknown role".into()),
    }
}
