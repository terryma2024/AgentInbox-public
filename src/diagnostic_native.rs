//! A fixed local model drives a real, isolated native tool call. It cannot issue
//! commands and does not produce adoption receipts; the original engine must do that.
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

pub struct Probe {
    pub test_id: String,
    pub expires: i64,
    pub start_rpc: u64,
    pub turn_rpc: Option<u64>,
    pub thread: Option<String>,
    pub callback_seen: bool,
    cwd: PathBuf,
    base_url: String,
    stop: Arc<AtomicBool>,
}
impl Probe {
    pub fn start(
        root: &Path,
        test: &str,
        expires: i64,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let cwd = root.join(format!("probe-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&cwd)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&cwd, std::fs::Permissions::from_mode(0o700))?;
        }
        let server = tiny_http::Server::http("127.0.0.1:0")
            .map_err(|_| "diagnostic provider unavailable")?;
        let route = format!("/{}/v1", uuid::Uuid::new_v4());
        let base_url = format!(
            "http://127.0.0.1:{}{}",
            server
                .server_addr()
                .to_ip()
                .ok_or("invalid provider address")?
                .port(),
            route
        );
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        std::thread::spawn(move || {
            let mut calls = 0;
            while !flag.load(Ordering::Relaxed) && crate::model::now() < expires {
                if let Ok(Some(request)) = server.recv_timeout(Duration::from_millis(100)) {
                    if request.url() != format!("{route}/responses")
                        || request.method() != &tiny_http::Method::Post
                        || calls >= 8
                    {
                        let _ = request.respond(tiny_http::Response::empty(404));
                        continue;
                    }
                    // Never parse, echo, log or persist model request contents.
                    // Keep reception and subsequent execution observably independent.
                    if calls > 0 {
                        std::thread::sleep(Duration::from_secs(2));
                    }
                    let events = fixed_events(calls == 0);
                    calls += 1;
                    let body = events
                        .iter()
                        .map(|v| format!("event: {}\ndata: {v}\n\n", v["type"].as_str().unwrap()))
                        .collect::<String>();
                    let response = tiny_http::Response::from_string(body).with_header(
                        tiny_http::Header::from_bytes("Content-Type", "text/event-stream").unwrap(),
                    );
                    let _ = request.respond(response);
                }
            }
        });
        Ok(Self {
            test_id: test.into(),
            expires,
            start_rpc: 0,
            turn_rpc: None,
            thread: None,
            callback_seen: false,
            cwd,
            base_url,
            stop,
        })
    }
    pub fn thread_params(&self) -> Value {
        json!({"cwd":self.cwd,"model":"agentinbox-diagnostic","modelProvider":"agentinbox_diagnostic","approvalPolicy":"never","sandbox":"read-only","baseInstructions":"Run only the fixed diagnostic question. Do not run commands or access user files.","config":{"model_providers.agentinbox_diagnostic":{"name":"AgentInbox local diagnostic","base_url":self.base_url,"wire_api":"responses","requires_openai_auth":false,"supports_websockets":false,"request_max_retries":0,"stream_max_retries":0},"model_reasoning_effort":"medium","web_search":"disabled"}})
    }
    pub fn turn_params(&self) -> Value {
        json!({"threadId":self.thread,"input":[{"type":"text","text":"Ask the diagnostic question."}],"collaborationMode":{"mode":"plan","settings":{"model":"agentinbox-diagnostic","reasoning_effort":"medium","developer_instructions":null}}})
    }
}
impl Drop for Probe {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = std::fs::remove_dir(&self.cwd);
    }
}
fn fixed_events(question: bool) -> Vec<Value> {
    let item = if question {
        json!({"type":"function_call","call_id":"diagnostic-call","name":"request_user_input","arguments":json!({"questions":[{"id":"diagnostic","header":"自检","question":"请选择测试回复；不会执行其他操作。","options":[{"label":"确认测试","description":"仅验证原调用收到本次测试答案"},{"label":"取消测试","description":"仍返回本次测试调用，不执行其他操作"}]}]}).to_string()})
    } else {
        json!({"type":"message","id":"diagnostic-message","role":"assistant","content":[{"type":"output_text","text":"Diagnostic continued."}]})
    };
    vec![
        json!({"type":"response.created","response":{"id":"diagnostic-response"}}),
        json!({"type":"response.output_item.done","item":item}),
        json!({"type":"response.completed","response":{"id":"diagnostic-response","usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0}}}),
    ]
}
