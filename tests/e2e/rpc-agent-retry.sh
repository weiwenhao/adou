#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

python3 - "$binary" <<'PY'
import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

binary = sys.argv[1]

def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()

def success_response():
    return b"".join([
        event({"id": "retry-success", "choices": [{"delta": {"role": "assistant", "content": "recovered"}, "finish_reason": None}]}),
        event({"id": "retry-success", "choices": [{"delta": {}, "finish_reason": "stop"}]}),
        event({"id": "retry-success", "choices": [], "usage": {"prompt_tokens": 2, "completion_tokens": 1, "total_tokens": 3}}),
        b"data: [DONE]\n\n",
    ])

class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests = 0

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        Provider.requests += 1
        if Provider.requests == 1:
            body = b'{"error":{"message":"503 service unavailable"}}'
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            return
        body = success_response()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
port = server.server_address[1]

with tempfile.TemporaryDirectory(prefix="adou-rpc-agent-retry-") as root:
    agent_dir = os.path.join(root, "agent")
    os.makedirs(agent_dir, exist_ok=True)
    with open(os.path.join(agent_dir, "settings.json"), "w", encoding="utf-8") as output:
        json.dump({
            "defaultProvider": "deepseek",
            "defaultModel": "deepseek-v4-flash",
            "defaultThinkingLevel": "off",
            "retryEnabled": True,
            "retryMaxAttempts": 1,
            "retryBaseDelayMs": 1,
        }, output, separators=(",", ":"))

    env = os.environ.copy()
    env.update({
        "ADOU_CODING_AGENT_DIR": agent_dir,
        "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
    })
    command = [
        binary, "--mode", "rpc", "--no-session", "--no-context-files",
        "--provider", "deepseek", "--model", "deepseek-v4-flash",
        "--thinking", "off", "--base-url", f"http://127.0.0.1:{port}",
        "--api-key", "rpc-agent-retry-key", "--max-retries", "0",
    ]
    proc = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        start_new_session=True,
        env=env,
    )
    seen = []
    try:
        proc.stdin.write(json.dumps({"id": "prompt", "type": "prompt", "message": "retry this"}) + "\n")
        proc.stdin.flush()
        deadline = __import__("time").monotonic() + 15
        while __import__("time").monotonic() < deadline:
            readable, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not readable:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            item = json.loads(line)
            seen.append(item)
            if item.get("type") == "session_end":
                break
        else:
            raise SystemExit(f"timed out waiting for retry session: {seen!r}")

        starts = [item for item in seen if item.get("type") == "auto_retry_start"]
        ends = [item for item in seen if item.get("type") == "auto_retry_end"]
        agent_ends = [item for item in seen if item.get("type") == "agent_end"]
        if len(starts) != 1 or starts[0].get("attempt") != 1 or starts[0].get("maxAttempts") != 1:
            raise SystemExit(f"Pi auto_retry_start payload mismatch: {seen!r}")
        if "503" not in starts[0].get("errorMessage", ""):
            raise SystemExit(f"Pi auto_retry_start errorMessage missing: {starts[0]!r}")
        if len(ends) != 1 or ends[0].get("success") is not True or ends[0].get("attempt") != 1:
            raise SystemExit(f"Pi auto_retry_end payload mismatch: {seen!r}")
        if [item.get("willRetry") for item in agent_ends] != [True, False]:
            raise SystemExit(f"Pi agent_end willRetry sequence mismatch: {seen!r}")
        if Provider.requests != 2:
            raise SystemExit(f"expected one retry request, got {Provider.requests}: {seen!r}")
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=3)
        server.shutdown()

print("e2e: RPC auto-retry event names, payloads, and willRetry ordering OK")
PY
