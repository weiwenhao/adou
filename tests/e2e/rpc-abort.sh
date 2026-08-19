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
ready = threading.Event()
release = threading.Event()

class SlowProvider(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        ready.set()
        # Hold the provider stream open until the client sends abort.  The
        # handler may observe a broken pipe once Nature closes the request.
        release.wait(8)
        try:
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except OSError:
            pass

    def log_message(self, *_args):
        pass

server = ThreadingHTTPServer(("127.0.0.1", 0), SlowProvider)
server_thread = threading.Thread(target=server.serve_forever, daemon=True)
server_thread.start()
port = server.server_address[1]

with tempfile.TemporaryDirectory(prefix="adou-rpc-abort-") as root:
    env = os.environ.copy()
    env.update({
        "ADOU_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
    })
    command = [
        binary, "--mode", "rpc", "--no-session", "--no-context-files",
        "--provider", "deepseek", "--model", "deepseek-v4-flash",
        "--base-url", f"http://127.0.0.1:{port}", "--api-key", "rpc-abort-key",
        "--max-retries", "0",
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
        proc.stdin.write(json.dumps({"id": "prompt", "type": "prompt", "message": "wait"}) + "\n")
        proc.stdin.flush()

        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            readable, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not readable:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            item = json.loads(line)
            seen.append(item)
            if item.get("type") == "response" and item.get("id") == "prompt":
                break
        else:
            raise SystemExit("did not receive prompt acknowledgement")

        # Ensure the HTTP request has entered the slow provider before abort.
        ready.wait(3)
        proc.stdin.write(json.dumps({"id": "abort", "type": "abort"}) + "\n")
        proc.stdin.flush()

        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            readable, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not readable:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            item = json.loads(line)
            seen.append(item)
            if item.get("type") == "response" and item.get("id") == "abort":
                break
        else:
            raise SystemExit("did not receive abort response")

        session_end = next((i for i, item in enumerate(seen) if item.get("type") == "session_end"), None)
        abort_response = next((i for i, item in enumerate(seen) if item.get("type") == "response" and item.get("id") == "abort"), None)
        if session_end is None:
            raise SystemExit(f"abort did not terminate the prompt stream: {seen!r}")
        settled = next((i for i, item in enumerate(seen) if item.get("type") == "agent_settled"), None)
        if settled is None or settled >= session_end:
            raise SystemExit(f"agent_settled was not emitted before session_end: {seen!r}")
        if abort_response is None or abort_response <= session_end:
            raise SystemExit(f"abort response was emitted before session_end: {seen!r}")
    finally:
        release.set()
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

print("e2e: RPC abort waits for session_end before response OK")
PY
