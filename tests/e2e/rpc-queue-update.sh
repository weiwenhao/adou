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
request_count = 0
request_lock = threading.Lock()

def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()

def completion_response():
    return b"".join([
        event({"id": "queue-turn", "choices": [{"delta": {"role": "assistant"}, "finish_reason": None}]}),
        event({"id": "queue-turn", "choices": [{"delta": {}, "finish_reason": "stop"}]}),
        b"data: [DONE]\n\n",
    ])

class QueueProvider(BaseHTTPRequestHandler):
    def do_POST(self):
        global request_count
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        with request_lock:
            request_count += 1
            current = request_count
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        if current == 1:
            ready.set()
            # Keep the first assistant turn active while both queue commands
            # are accepted. Later turns complete immediately.
            release.wait(8)
        try:
            body = completion_response()
            self.wfile.write(body)
            self.wfile.flush()
        except OSError:
            pass

    def log_message(self, *_args):
        pass

server = ThreadingHTTPServer(("127.0.0.1", 0), QueueProvider)
server_thread = threading.Thread(target=server.serve_forever, daemon=True)
server_thread.start()
port = server.server_address[1]

with tempfile.TemporaryDirectory(prefix="adou-rpc-queue-update-") as root:
    env = os.environ.copy()
    env.update({
        "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
    })
    command = [
        binary, "--mode", "rpc", "--no-session", "--no-context-files",
        "--provider", "deepseek", "--model", "deepseek-v4-flash",
        "--base-url", f"http://127.0.0.1:{port}", "--api-key", "rpc-queue-key",
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

    def read_until(predicate, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            readable, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not readable:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            item = json.loads(line)
            seen.append(item)
            if predicate(item):
                return
        raise SystemExit(f"timed out waiting for RPC event: {seen!r}")

    try:
        proc.stdin.write(json.dumps({"id": "prompt", "type": "prompt", "message": "start"}) + "\n")
        proc.stdin.flush()
        read_until(lambda item: item.get("type") == "response" and item.get("id") == "prompt", 5)
        if not ready.wait(3):
            raise SystemExit("provider did not receive the initial request")

        proc.stdin.write(json.dumps({"id": "steer", "type": "steer", "message": "steer me"}) + "\n")
        proc.stdin.write(json.dumps({"id": "follow", "type": "follow_up", "message": "follow me"}) + "\n")
        proc.stdin.flush()
        read_until(
            lambda item: item.get("type") == "response" and item.get("id") == "follow",
            5,
        )
        release.set()
        read_until(lambda item: item.get("type") == "session_end", 8)

        snapshots = [
            (tuple(item.get("steering", [])), tuple(item.get("followUp", [])))
            for item in seen
            if item.get("type") == "queue_update"
        ]
        expected = [
            (("steer me",), ()),
            (("steer me",), ("follow me",)),
            ((), ("follow me",)),
            ((), ()),
        ]
        for snapshot in expected:
            if snapshot not in snapshots:
                raise SystemExit(f"missing queue snapshot {snapshot!r}: {snapshots!r}")

        for text, snapshot in (("steer me", ((), ("follow me",))), ("follow me", ((), ()) )):
            message_index = next(
                (index for index, item in enumerate(seen)
                 if item.get("type") == "message_start"
                 and item.get("message", {}).get("content") == text),
                None,
            )
            if message_index is None or message_index == 0:
                raise SystemExit(f"queued message_start not found: {text!r}: {seen!r}")
            previous = seen[message_index - 1]
            actual = (tuple(previous.get("steering", [])), tuple(previous.get("followUp", [])))
            if previous.get("type") != "queue_update" or actual != snapshot:
                raise SystemExit(f"queue_update did not precede {text!r}: {seen!r}")
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

print("e2e: RPC queue_update snapshots and delivery ordering OK")
PY
