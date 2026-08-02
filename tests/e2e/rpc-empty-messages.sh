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
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import sys

binary = sys.argv[1]


def sse_event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()


def completion_response():
    return b"".join(
        [
            sse_event({"id": "empty-message", "choices": [{"delta": {"role": "assistant"}, "finish_reason": None}]}),
            sse_event({"id": "empty-message", "choices": [{"delta": {"content": "ok"}, "finish_reason": None}]}),
            sse_event({"id": "empty-message", "choices": [{"delta": {}, "finish_reason": "stop"}]}),
            b"data: [DONE]\n\n",
        ]
    )


class Provider(BaseHTTPRequestHandler):
    ready = None
    release = None
    hold_first = False
    request_count = 0
    request_lock = threading.Lock()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        with self.request_lock:
            self.__class__.request_count += 1
            current = self.__class__.request_count
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        if self.__class__.hold_first and current == 1:
            self.__class__.ready.set()
            self.__class__.release.wait(8)
        try:
            self.wfile.write(completion_response())
            self.wfile.flush()
        except OSError:
            pass

    def log_message(self, *_args):
        pass


def start_server(hold_first):
    handler = type("TestProvider", (Provider,), {})
    handler.ready = threading.Event()
    handler.release = threading.Event()
    handler.hold_first = hold_first
    handler.request_count = 0
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, handler


def start_process(root, port):
    env = os.environ.copy()
    env.update(
        {
            "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
            "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
        }
    )
    return subprocess.Popen(
        [
            binary,
            "--mode",
            "rpc",
            "--no-session",
            "--no-context-files",
            "--provider",
            "deepseek",
            "--model",
            "deepseek-v4-flash",
            "--base-url",
            f"http://127.0.0.1:{port}",
            "--api-key",
            "rpc-empty-key",
            "--max-retries",
            "0",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        start_new_session=True,
        env=env,
    )


def read_until(proc, seen, predicate, timeout=8):
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
            return item
    raise SystemExit(f"timed out waiting for RPC event: {seen!r}")


def stop_process(proc):
    try:
        proc.stdin.close()
    except OSError:
        pass
    try:
        proc.wait(timeout=4)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=4)
    if proc.returncode != 0:
        error = proc.stderr.read()
        raise SystemExit(f"Adou exited with {proc.returncode}: {error}")


with tempfile.TemporaryDirectory(prefix="adou-rpc-empty-prompt-") as root:
    server, handler = start_server(False)
    proc = start_process(root, server.server_address[1])
    seen = []
    try:
        proc.stdin.write(json.dumps({"id": "empty-prompt", "type": "prompt", "message": ""}) + "\n")
        proc.stdin.flush()
        response = read_until(proc, seen, lambda item: item.get("id") == "empty-prompt")
        if response.get("success") is not True:
            raise SystemExit(f"empty prompt was rejected: {seen!r}")
        read_until(proc, seen, lambda item: item.get("type") == "session_end")
        starts = [
            item
            for item in seen
            if item.get("type") == "message_start"
            and item.get("message", {}).get("role") == "user"
        ]
        if not starts or starts[0].get("message", {}).get("content") != "":
            raise SystemExit(f"empty prompt did not reach the provider as an empty user message: {seen!r}")
    finally:
        stop_process(proc)
        server.shutdown()

with tempfile.TemporaryDirectory(prefix="adou-rpc-empty-queue-") as root:
    server, handler = start_server(True)
    proc = start_process(root, server.server_address[1])
    seen = []
    try:
        proc.stdin.write(json.dumps({"id": "initial", "type": "prompt", "message": "start"}) + "\n")
        proc.stdin.flush()
        read_until(proc, seen, lambda item: item.get("id") == "initial")
        if not handler.ready.wait(3):
            raise SystemExit("provider did not receive the initial request")
        proc.stdin.write(json.dumps({"id": "busy-prompt", "type": "prompt", "message": "must queue explicitly"}) + "\n")
        proc.stdin.flush()
        busy_response = read_until(proc, seen, lambda item: item.get("id") == "busy-prompt")
        expected_error = "Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message."
        if busy_response.get("success") is not False or busy_response.get("error") != expected_error:
            raise SystemExit(f"busy prompt did not return Pi queue guidance: {seen!r}")
        proc.stdin.write(json.dumps({"id": "empty-steer", "type": "steer", "message": ""}) + "\n")
        proc.stdin.write(json.dumps({"id": "empty-follow", "type": "follow_up", "message": ""}) + "\n")
        proc.stdin.flush()
        read_until(proc, seen, lambda item: item.get("id") == "empty-steer")
        read_until(proc, seen, lambda item: item.get("id") == "empty-follow")
        handler.release.set()
        read_until(proc, seen, lambda item: item.get("type") == "session_end", 12)
        snapshots = [
            (tuple(item.get("steering", [])), tuple(item.get("followUp", [])))
            for item in seen
            if item.get("type") == "queue_update"
        ]
        expected = [(('',), ()), (('',), ('',)), ((), ('',)), ((), ())]
        for snapshot in expected:
            if snapshot not in snapshots:
                raise SystemExit(f"empty queue snapshot missing: {snapshot!r}: {snapshots!r}")
    finally:
        handler.release.set()
        stop_process(proc)
        server.shutdown()

print("e2e: Pi accepts empty prompt, steering, and follow-up messages")
PY
