#!/usr/bin/env python3
"""Controlled real-engine qualification with a local deterministic model fixture.

No credentials, installed Codex daemon, phone, or external model calls are needed.
All raw native IDs and rollout records stay in the explicitly private output dir.
"""
import argparse
import base64
import gzip
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import threading
import time
import uuid


class UnixWebSocket:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(30)
        self.socket.connect(str(Path(path).resolve()))
        key = base64.b64encode(os.urandom(16)).decode()
        self.socket.sendall(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                             "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                             f"Sec-WebSocket-Key: {key}\r\n\r\n").encode())
        response = bytearray()
        while not response.endswith(b"\r\n\r\n"):
            response += self.exact(1)
        assert response.startswith(b"HTTP/1.1 101"), "WebSocket upgrade rejected"
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        assert expected.lower() in bytes(response).lower(), "Invalid WebSocket accept"
        self.messages = []
        self.pending = []
        self.next_id = 1

    def exact(self, size):
        result = bytearray()
        while len(result) < size:
            chunk = self.socket.recv(size - len(result))
            if not chunk:
                raise RuntimeError("Native transport closed")
            result += chunk
        return bytes(result)

    def send(self, value):
        data = json.dumps(value, separators=(",", ":")).encode()
        mask = os.urandom(4)
        if len(data) < 126:
            header = bytes([0x81, 0x80 | len(data)])
        elif len(data) < 65536:
            header = bytes([0x81, 0x80 | 126]) + struct.pack("!H", len(data))
        else:
            header = bytes([0x81, 0x80 | 127]) + struct.pack("!Q", len(data))
        self.socket.sendall(header + mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(data)))

    def receive(self):
        while True:
            first, second = self.exact(2)
            size = second & 127
            if size == 126:
                size = struct.unpack("!H", self.exact(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.exact(8))[0]
            mask = self.exact(4) if second & 128 else None
            payload = self.exact(size)
            if mask:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            if first & 15 == 8:
                raise RuntimeError("Native WebSocket closed")
            if first & 15 != 1:
                raise RuntimeError("Unexpected non-text WebSocket frame")
            assert first & 0x80, "Fixture expects unfragmented frames"
            value = json.loads(payload)
            self.messages.append(value)
            return value

    def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self.send({"id": request_id, "method": method, "params": params})
        while True:
            message = self.receive()
            if message.get("id") == request_id and "method" not in message:
                assert "error" not in message, f"Native {method} request failed"
                return message["result"]
            self.pending.append(message)

    def until(self, method):
        for index, message in enumerate(self.pending):
            if message.get("method") == method:
                return self.pending.pop(index)
        while True:
            message = self.receive()
            if message.get("method") == method:
                return message
            self.pending.append(message)


def sse(events):
    return "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()


def fixture_events(question):
    prefix = [{"type": "response.created", "response": {"id": "fixture-response"}}]
    if question:
        arguments = {"questions": [{"id": "route", "header": "Route", "question": "AGENTINBOX_CHOOSE_ROUTE",
                                   "options": [{"label": "Alpha", "description": "Choose Alpha"},
                                               {"label": "Beta", "description": "Choose Beta"}]}]}
        item = {"type": "function_call", "call_id": "fixture-call", "name": "request_user_input",
                "arguments": json.dumps(arguments)}
    else:
        item = {"type": "message", "id": "fixture-message", "role": "assistant",
                "content": [{"type": "output_text", "text": "Fixture continued."}]}
    return prefix + [{"type": "response.output_item.done", "item": item},
                     {"type": "response.completed", "response": {"id": "fixture-response",
                      "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}}}]


def run_case(binary, output, phone_first):
    output.mkdir(mode=0o700)
    home = output / "home"
    receipts = output / "receipts"
    home.mkdir(mode=0o700)
    receipts.mkdir(mode=0o700)
    captured = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            captured.append(json.loads(body))
            response = sse(fixture_events(len(captured) == 1))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

        def log_message(self, *_):
            pass

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    (home / "config.toml").write_text(f'''model = "fixture-model"
model_provider = "fixture"
approval_policy = "never"
sandbox_mode = "read-only"
[model_providers.fixture]
name = "Local deterministic fixture"
base_url = "http://127.0.0.1:{provider.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
''')
    socket_path = output / "control.sock"
    env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "SYSTEMROOT") if key in os.environ}
    env.update(HOME=str(home), CODEX_HOME=str(home), AGENTINBOX_NATIVE_RECEIPT_DIR=str(receipts),
               CODEX_APP_SERVER_DISABLE_MANAGED_CONFIG="1", RUST_LOG="warn")
    log = (output / "engine.log").open("wb")
    process = subprocess.Popen([str(binary), "--listen", f"unix://{socket_path}",
                                "--disable-plugin-startup-tasks-for-tests"], env=env, stdout=log, stderr=log)
    clients = []
    try:
        deadline = time.monotonic() + 30
        while not socket_path.exists():
            assert process.poll() is None, "Native engine exited during startup; inspect private engine log"
            assert time.monotonic() < deadline, "Native socket startup timed out"
            time.sleep(0.05)
        for _ in range(2):
            client = UnixWebSocket(socket_path)
            clients.append(client)
            client.request("initialize", {"clientInfo": {"name": "agentinbox_fixture", "version": "1"},
                                           "capabilities": {"experimentalApi": True}})
            client.send({"method": "initialized"})
        local, phone = clients
        thread = local.request("thread/start", {"cwd": str(output), "model": "fixture-model",
                                                "approvalPolicy": "never", "sandbox": "read-only"})["thread"]
        local.request("turn/start", {"threadId": thread["id"], "input": [{"type": "text", "text": "Ask the fixture question."}],
                                      "collaborationMode": {"mode": "plan", "settings": {"model": "fixture-model",
                                         "reasoning_effort": "medium", "developer_instructions": None}}})
        callback = local.until("item/tool/requestUserInput")
        phone.request("thread/resume", {"threadId": thread["id"]})
        phone_callback = phone.until("item/tool/requestUserInput")
        assert callback == phone_callback, "Both clients must compete for the same native callback"
        manifest = json.loads((receipts / "manifest.json").read_text())
        assert manifest["nativePid"] == process.pid
        original = {"answers": {"route": {"answers": ["Beta"]}}}
        dispatch = str(uuid.uuid4())
        digest = hashlib.sha256(json.dumps({"callback": callback, "result": original}, sort_keys=True).encode()).hexdigest()
        envelope = dict(original, _agentinboxReceipt={"schemaVersion": 1, "dispatchId": dispatch,
                        "bindingDigest": digest, "nativeInstanceId": manifest["nativeInstanceId"]})
        winner, loser = (phone, local) if phone_first else (local, phone)
        winner.send({"id": callback["id"], "result": envelope if phone_first else original})
        winner.until("serverRequest/resolved")
        loser.send({"id": callback["id"], "result": original if phone_first else envelope})
        local.until("turn/completed")
        assert len(captured) == 2, "Original execution must continue to the next model request"
        outputs = [item for item in captured[1]["input"] if item.get("type") == "function_call_output"
                   and item.get("call_id") == "fixture-call"]
        assert len(outputs) == 1
        original_output = outputs[0]["output"]
        if isinstance(original_output, str):
            original_output = json.loads(original_output)
        assert original_output == original, "Original tool output must preserve exact answer without metadata"
        receipt_path = receipts / f"dispatch-{dispatch}.json"
        if phone_first:
            receipt = json.loads(receipt_path.read_text())
            assert receipt["callback"] == callback
            assert receipt["result"] == original
            assert receipt["bindingDigest"] == digest
            assert receipt["nativePid"] == process.pid
            assert receipt["nativeInstanceId"] == manifest["nativeInstanceId"]
            assert receipt_path.stat().st_mode & 0o777 == 0o600
        else:
            assert not receipt_path.exists(), "Same-value local winner must never confirm phone reception"
        assert len(list(receipts.glob("dispatch-*.json"))) == int(phone_first)
        (output / "captured-model-requests.json").write_text(json.dumps(captured, indent=2))
        for index, client in enumerate(clients):
            (output / f"client-{index}.json").write_text(json.dumps(client.messages, indent=2))
        return {"winner": "phone" if phone_first else "local", "nativeArbitration": True,
                "exactOriginalOutput": True, "continued": True, "receiptCount": int(phone_first)}
    finally:
        for index, client in enumerate(clients):
            (output / f"client-{index}.json").write_text(json.dumps(client.messages, indent=2))
            client.socket.close()
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()
        provider.shutdown()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.umask(0o077)
    results = [run_case(args.binary.resolve(), output / name, first)
               for name, first in (("phone-winner", True), ("local-winner", False))]
    (output / "summary.json").write_text(json.dumps({"schemaVersion": 1, "cases": results}, indent=2))
    print(json.dumps({"cases": results}))


if __name__ == "__main__":
    main()
