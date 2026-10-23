#!/usr/bin/env python3
"""Loopback-only, synthetic Widget UI fixture; never connects to an Agent.

Run with --directory /absolute/local/output, then pass probe.json to the
explicitly enabled WidgetSurfaceTests. All credentials and requests are public
fixtures and must never be provisioned on a real service.
"""
import argparse
import json
from pathlib import Path
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4

KEY = "public-widget-fixture-only-never-provision"


class Fixture:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        run = uuid4().hex
        now = time.time()
        self.requests = []
        self.posts = []
        self.offline = False
        for index, title in enumerate(["第一题", "第二题", "文字原题"]):
            self.requests.append(dict(
                requestId=f"fixture-widget-{index}-{run}", revision=1,
                expiresAt=now + 3600, state="pending",
                kind="text" if index == 2 else "choice", hostId="example-host",
                engine="codex", runtimeId="fixture-runtime", sessionId="fixture-session",
                turnId="fixture-turn", nativeRequestId=f"fixture-call-{index}",
                title=title, body="请写下说明。" if index == 2 else "请选择路线。",
                options=[] if index == 2 else [dict(id="alpha", label="甲"), dict(id="beta", label="乙")],
                multiSelect=False, createdAt=now - 90, updatedAt=now,
                projectPath="/srv/example-project"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    fixture = Fixture()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, value, status=200):
            data = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            with fixture.lock:
                if self.path == "/fixture/state":
                    return self.respond(dict(requests=fixture.requests, posts=fixture.posts))
                if self.headers.get("Authorization") != "Bearer " + KEY:
                    return self.respond({}, 401)
                if fixture.offline:
                    return self.respond({}, 503)
                if self.path == "/v1/requests":
                    return self.respond(dict(requests=fixture.requests))
                if self.path == "/v1/hosts":
                    return self.respond(dict(hosts=[]))
                for request in fixture.requests:
                    if self.path == "/v1/requests/" + request["requestId"]:
                        return self.respond(request)
                return self.respond({}, 404)

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            with fixture.lock:
                if self.path == "/fixture/reset":
                    fixture.reset()
                    return self.respond({})
                if self.path == "/fixture/offline":
                    fixture.offline = True
                    return self.respond({})
                if self.headers.get("Authorization") != "Bearer " + KEY:
                    return self.respond({}, 401)
                request = next((r for r in fixture.requests if self.path == "/v1/requests/" + r["requestId"] + "/responses"), None)
                if request is None:
                    return self.respond({}, 404)
                if request["state"] != "pending" or body.get("requestId") != request["requestId"] or body.get("revision") != 1 or body.get("optionIds") not in [["alpha"], ["beta"]]:
                    return self.respond({}, 409)
                fixture.posts.append(body)
                request["state"] = "submitting"
                request["responseId"] = body["responseId"]
            # Keep the actual Intent in flight long enough to observe pending UI.
            time.sleep(5)
            with fixture.lock:
                request["state"] = "adopted"
                return self.respond(dict(requestId=request["requestId"], responseId=body["responseId"], state="submitting"))

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    key_file = directory / "fixture-key.txt"
    key_file.write_text(KEY)
    key_file.chmod(0o600)
    probe = dict(serverURL=f"http://127.0.0.1:{server.server_port}", tokenFile=str(key_file))
    (directory / "probe.json").write_text(json.dumps(probe))
    print(probe["serverURL"], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
