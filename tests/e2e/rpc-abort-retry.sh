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
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

binary = sys.argv[1]

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
        body = b'{"error":{"message":"503 service unavailable"}}'
        self.send_response(503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
port = server.server_address[1]

with tempfile.TemporaryDirectory(prefix="adou-rpc-abort-retry-") as root:
    agent_dir = os.path.join(root, "agent")
    os.makedirs(agent_dir, exist_ok=True)
    with open(os.path.join(agent_dir, "settings.json"), "w", encoding="utf-8") as output:
        json.dump(
            {
                "defaultProvider": "deepseek",
                "defaultModel": "deepseek-v4-flash",
                "defaultThinkingLevel": "off",
                "retryEnabled": True,
                "retryMaxAttempts": 1,
                "retryBaseDelayMs": 2000,
            },
            output,
            separators=(",", ":"),
        )

    env = os.environ.copy()
    env.update(
        {
            "PI_CODING_AGENT_DIR": agent_dir,
            "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
        }
    )
    command = [
        binary,
        "--mode",
        "rpc",
        "--no-session",
        "--no-context-files",
        "--provider",
        "deepseek",
        "--model",
        "deepseek-v4-flash",
        "--thinking",
        "off",
        "--base-url",
        f"http://127.0.0.1:{port}",
        "--api-key",
        "rpc-abort-retry-key",
        "--max-retries",
        "0",
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
    abort_sent = False
    try:
        proc.stdin.write(json.dumps({"id": "prompt", "type": "prompt", "message": "cancel retry"}) + "\n")
        proc.stdin.flush()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            readable, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not readable:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            item = json.loads(line)
            seen.append(item)
            if item.get("type") == "auto_retry_start" and not abort_sent:
                proc.stdin.write(json.dumps({"id": "abort-retry", "type": "abort_retry"}) + "\n")
                proc.stdin.flush()
                abort_sent = True
            if item.get("type") == "session_end":
                break
        else:
            raise SystemExit(f"timed out waiting for cancelled retry session: {seen!r}")

        starts = [item for item in seen if item.get("type") == "auto_retry_start"]
        ends = [item for item in seen if item.get("type") == "auto_retry_end"]
        abort_responses = [
            item
            for item in seen
            if item.get("type") == "response" and item.get("id") == "abort-retry"
        ]
        prompt_responses = [
            item
            for item in seen
            if item.get("type") == "response" and item.get("id") == "prompt"
        ]
        if not abort_sent:
            raise SystemExit(f"auto_retry_start was not observed: {seen!r}")
        if len(starts) != 1 or starts[0].get("attempt") != 1:
            raise SystemExit(f"Pi auto_retry_start payload mismatch: {seen!r}")
        if len(ends) != 1 or ends[0].get("success") is not False or ends[0].get("finalError") != "Retry cancelled":
            raise SystemExit(f"Pi auto_retry_end cancellation payload mismatch: {seen!r}")
        if len(abort_responses) != 1 or abort_responses[0].get("success") is not True:
            raise SystemExit(f"abort_retry response missing or failed: {seen!r}")
        if len(prompt_responses) != 1 or prompt_responses[0].get("success") is not True:
            raise SystemExit(f"prompt response missing or failed: {seen!r}")
        if not any(item.get("type") == "session_end" for item in seen):
            raise SystemExit(f"session_end missing after cancelled retry: {seen!r}")
        if Provider.requests != 1:
            raise SystemExit(f"abort_retry cancelled the wrong scope; requests={Provider.requests}: {seen!r}")
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
        if proc.returncode not in (0,):
            error = proc.stderr.read()
            if error:
                sys.stderr.write(error)
        server.shutdown()

print("e2e: RPC abort_retry cancels only the retry backoff OK")
PY
