use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Read, Write},
    os::unix::net::UnixStream,
    time::Duration,
};

pub fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let socket = args
        .first()
        .ok_or("hook SOCKET [TIMEOUT_SECONDS] required")?;
    let timeout = args
        .get(1)
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(60)
        .clamp(5, 3600);
    let mut input = String::new();
    std::io::stdin()
        .take(1_048_577)
        .read_to_string(&mut input)?;
    if input.len() > 1_048_576 {
        return Err("hook payload exceeds 1 MiB".into());
    }
    let event: Value = serde_json::from_str(&input)?;
    let result = (|| -> Result<Value, Box<dyn std::error::Error>> {
        let mut stream = UnixStream::connect(socket)?;
        stream.set_read_timeout(Some(Duration::from_secs(timeout)))?;
        stream.set_write_timeout(Some(Duration::from_secs(3)))?;
        writeln!(
            stream,
            "{}",
            json!({"hookEvent":event,"deadline":crate::host::now()+timeout as i64,"helperPid":std::process::id(),"engineRuntime":claude_runtime()})
        )?;
        stream.flush()?;
        let mut line = String::new();
        BufReader::new(&mut stream)
            .take(1_048_577)
            .read_line(&mut line)?;
        let reply: Value = serde_json::from_str(&line)?;
        reply
            .get("output")
            .cloned()
            .ok_or_else(|| "host did not supply a bound hook output".into())
    })();
    match result {
        Ok(output) => println!("{}", output),
        Err(_) => {
            // Empty hook output falls back to the tool's native UX. It never grants approval.
            eprintln!("AgentInbox: 无已绑定答案，交回原工具界面；未批准操作。");
            println!("{}", json!({}));
        }
    }
    std::io::stdout().flush()?;
    Ok(())
}
pub fn control(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let socket = args
        .first()
        .ok_or("hostctl SOCKET [status|drain|prepare-upgrade] required")?;
    let op = args.get(1).map(String::as_str).unwrap_or("status");
    if !["status", "drain", "prepare-upgrade"].contains(&op) {
        return Err("unknown control operation".into());
    }
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    writeln!(stream, "{}", json!({"operation":op}))?;
    let mut out = String::new();
    BufReader::new(stream).read_line(&mut out)?;
    print!("{out}");
    let status: Value = serde_json::from_str(&out)?;
    if status.get("error").is_some() {
        return Err("host refused control operation; no process stopped".into());
    }
    if op == "prepare-upgrade" {
        if status["readyForUpgrade"] != true || status["draining"] != true {
            return Err("upgrade deferred; host remains draining, no process stopped".into());
        }
    }
    Ok(())
}

fn claude_runtime() -> Option<String> {
    let mut pid = std::process::id();
    for _ in 0..8 {
        let out = std::process::Command::new("/bin/ps")
            .args([
                "-p",
                &pid.to_string(),
                "-o",
                "ppid=",
                "-o",
                "lstart=",
                "-o",
                "comm=",
            ])
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let row = String::from_utf8(out.stdout).ok()?;
        let words: Vec<_> = row.split_whitespace().collect();
        if words.len() < 7 {
            return None;
        }
        let command = words[6..].join(" ");
        if std::path::Path::new(&command)
            .file_name()
            .and_then(|s| s.to_str())
            == Some("claude")
        {
            return Some(format!("claude:{pid}:{}", words[1..6].join(" ")));
        }
        pid = words[0].parse().ok()?;
        if pid <= 1 {
            return None;
        }
    }
    None
}
