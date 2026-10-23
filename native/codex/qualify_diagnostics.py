#!/usr/bin/env python3
"""Isolated real-native self-check integration. Never reads an installation config."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.error
import urllib.request


def run(binary, engine, output, serve_app=False):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    children = []
    handles = []
    device = "public-diagnostic-device-fixture-0001"
    host = "public-diagnostic-host-fixture-000001"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(path, value=None, token=device):
        data = None if value is None else json.dumps(value).encode()
        request = urllib.request.Request(base + path, data=data, headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        with opener.open(request, timeout=4) as response:
            return json.load(response)

    def wait(check, seconds=35):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                result = check()
                if result:
                    return result
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.1)
        raise AssertionError("Isolated diagnostic phase timed out; inspect local fixture logs")

    def spawn(name, args, env=None):
        log = (output / f"{name}.log").open("wb")
        handles.append(log)
        child = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        children.append(child)
        return child

    try:
        relay_config = output / "relay.json"
        relay_config.write_text(json.dumps({"listen": f"127.0.0.1:{port}", "database": str(output / "relay.sqlite"), "credentials": [{"id": "fixture-device", "token": device, "role": "device"}, {"id": "fixture-host-credential", "token": host, "role": "host", "hostId": "fixture-host"}], "apns": None}))
        spawn("relay", [str(binary), "relay", "--config", str(relay_config)])
        wait(lambda: call("/v1/capabilities").get("diagnosticsVersion") == 1)
        home = output / "engine-home"
        home.mkdir(mode=0o700)
        receipts = output / "receipts"
        receipts.mkdir(mode=0o700)
        native_socket = output / "native.sock"
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home), "CODEX_HOME": str(home), "AGENTINBOX_NATIVE_RECEIPT_DIR": str(receipts), "CODEX_APP_SERVER_DISABLE_MANAGED_CONFIG": "1", "RUST_LOG": "warn"}
        spawn("engine", [str(engine), "--listen", f"unix://{native_socket}", "--disable-plugin-startup-tasks-for-tests"], env)
        wait(native_socket.exists)
        token = output / "host.token"
        token.write_text(host)
        token.chmod(0o600)
        state = output / "state"
        state.mkdir(mode=0o700)
        config = output / "host.json"
        config.write_text(json.dumps({"hostId": "fixture-host", "relayUrl": base, "tokenFile": str(token), "stateDir": str(state), "ipcSocket": str(state / "host.sock"), "codexSocket": str(native_socket), "nativeReceiptDir": str(receipts), "scopes": [str(output)], "captureLoadedNative": False}))
        spawn("host", [str(binary), "host", str(config)])
        wait(lambda: call("/v1/diagnostics")["hosts"])
        if serve_app:
            device_file = output / "device.token"
            device_file.write_text(device)
            device_file.chmod(0o600)
            (output / "probe.json").write_text(json.dumps({"serverURL": base, "tokenFile": str(device_file)}))
            print("Isolated App diagnostic fixture ready", flush=True)
            deadline = time.monotonic() + 240
            while time.monotonic() < deadline and not (output / "stop").exists():
                time.sleep(0.2)
            return
        test_id = "fixture-diagnostic-test"
        call("/v1/diagnostics/tests", {"testId": test_id, "hostId": "fixture-host", "mode": "reply"})
        path = f"/v1/diagnostics/tests/{test_id}"
        status = wait(lambda: (s if (s := call(path)).get("request") else None), seconds=55)
        assert status["received"] is False
        assert status["continued"] is False
        request = status["request"]
        assert call("/v1/requests")["requests"] == [], "Test leaked into ordinary inbox"
        answer = {"requestId": request["requestId"], "responseId": "fixture-diagnostic-answer", "revision": request["revision"], "optionIds": [request["options"][0]["id"]], "answers": {}, "bindingDigest": request["bindingDigest"]}
        call(f'/v1/requests/{request["requestId"]}/responses', answer)
        received = wait(lambda: (s if (s := call(path))["received"] else None))
        assert received["continued"] is False, "Reception must be observed independently before continuation"
        completed = wait(lambda: (s if (s := call(path))["continued"] else None))
        assert received["request"]["replyProgress"]["responseId"] == "fixture-diagnostic-answer"
        assert completed["phase"] == "complete"
        assert completed["push"] != "accepted", "No APNs configured for this isolated test"
        summary = {"nativeOriginalReceived": True, "receptionBeforeContinuation": True, "nativeContinued": True, "normalInboxUnaffected": True, "externalModelUsed": False, "apnsTested": False}
        (output / "summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary))
    finally:
        for child in reversed(children):
            child.terminate()
        for child in reversed(children):
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for handle in handles:
            handle.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--native-binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--serve-app-fixture", action="store_true")
    args = parser.parse_args()
    run(args.binary.resolve(), args.native_binary.resolve(), args.output.resolve(), args.serve_app_fixture)
