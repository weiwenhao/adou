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


def summary_response():
    body = b"".join(
        [
            event(
                {
                    "id": "summary-retry",
                    "choices": [
                        {"delta": {"role": "assistant", "content": "## Goal\nretry recovered"}, "finish_reason": None}
                    ],
                }
            ),
            event(
                {
                    "id": "summary-retry",
                    "choices": [{"delta": {}, "finish_reason": "stop"}],
                }
            ),
            event(
                {
                    "id": "summary-retry",
                    "choices": [],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 8, "total_tokens": 18},
                }
            ),
            b"data: [DONE]\n\n",
        ]
    )
    return body


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
            body = b'{"error":{"message":"temporary service unavailable"}}'
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            return

        body = summary_response()
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


def read_until(proc, seen, predicate, timeout):
    deadline = __import__("time").monotonic() + timeout
    while __import__("time").monotonic() < deadline:
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
    return None


with tempfile.TemporaryDirectory(prefix="adou-rpc-compaction-retry-") as root:
    cwd = os.getcwd()
    session_file = os.path.join(root, "seed.jsonl")
    agent_dir = os.path.join(root, "agent")
    os.makedirs(agent_dir, exist_ok=True)
    settings = {
        "defaultProvider": "deepseek",
        "defaultModel": "deepseek-v4-flash",
        "defaultThinkingLevel": "off",
        "retryEnabled": True,
        "retryMaxAttempts": 1,
        "retryBaseDelayMs": 1,
    }
    with open(os.path.join(agent_dir, "settings.json"), "w", encoding="utf-8") as output:
        json.dump(settings, output, separators=(",", ":"))

    seed = [
        {
            "type": "session",
            "version": 3,
            "id": "rpc-compaction-retry",
            "timestamp": "2026-01-01T00:00:00.000Z",
            "cwd": cwd,
        },
        {
            "type": "model_change",
            "id": "m1",
            "parentId": None,
            "timestamp": "2026-01-01T00:00:01.000Z",
            "provider": "deepseek",
            "modelId": "deepseek-v4-flash",
        },
        {
            "type": "thinking_level_change",
            "id": "t1",
            "parentId": "m1",
            "timestamp": "2026-01-01T00:00:02.000Z",
            "thinkingLevel": "off",
        },
        {
            "type": "message",
            "id": "u1",
            "parentId": "t1",
            "timestamp": "2026-01-01T00:00:03.000Z",
            "message": {"role": "user", "content": "old request to summarize", "timestamp": 1},
        },
        {
            "type": "message",
            "id": "a1",
            "parentId": "u1",
            "timestamp": "2026-01-01T00:00:04.000Z",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": "old answer to retain in the summary"}],
                "api": "openai-completions",
                "provider": "deepseek",
                "model": "deepseek-v4-flash",
                "stopReason": "stop",
                "timestamp": 2,
            },
        },
    ]
    with open(session_file, "w", encoding="utf-8") as output:
        for entry in seed:
            output.write(json.dumps(entry, separators=(",", ":")) + "\n")

    env = os.environ.copy()
    env.update(
        {
            "ADOU_CODING_AGENT_DIR": agent_dir,
            "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
        }
    )
    command = [
        binary,
        "--mode",
        "rpc",
        "--session",
        session_file,
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
        "rpc-compaction-retry-key",
        "--max-retries",
        "0",
        "--reserve-tokens",
        "100",
        "--keep-recent-tokens",
        "1",
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
        proc.stdin.write(json.dumps({"id": "compact", "type": "compact", "customInstructions": "preserve the goal"}) + "\n")
        proc.stdin.flush()
        response = read_until(
            proc,
            seen,
            lambda item: item.get("type") == "response" and item.get("id") == "compact",
            15,
        )
        if response is None:
            raise SystemExit(f"did not receive compact response: {seen!r}")
        if response.get("success") is not True:
            raise SystemExit(f"compaction retry failed: {response!r}; events={seen!r}")
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

    scheduled = next((item for item in seen if item.get("type") == "summarization_retry_scheduled"), None)
    attempt = next((item for item in seen if item.get("type") == "summarization_retry_attempt_start"), None)
    finished = next((item for item in seen if item.get("type") == "summarization_retry_finished"), None)
    if not scheduled or scheduled.get("attempt") != 1 or scheduled.get("maxAttempts") != 1:
        raise SystemExit(f"Pi summarization retry scheduled event missing: {seen!r}")
    if "503" not in scheduled.get("errorMessage", ""):
        raise SystemExit(f"retry error message missing provider status: {scheduled!r}")
    if not attempt or attempt.get("source") != "compaction" or attempt.get("reason") != "manual":
        raise SystemExit(f"Pi compaction retry attempt event missing source/reason: {seen!r}")
    if not finished or set(finished) != {"type"}:
        raise SystemExit(f"summarization retry finished event has non-Pi fields: {finished!r}")
    if Provider.requests != 2:
        raise SystemExit(f"expected one failed and one recovered provider request, got {Provider.requests}")
    scheduled_index = seen.index(scheduled)
    attempt_index = seen.index(attempt)
    finished_index = seen.index(finished)
    response_index = seen.index(response)
    if not scheduled_index < attempt_index < finished_index < response_index:
        raise SystemExit(f"summarization retry event order differs from Pi: {seen!r}")
    with open(session_file, encoding="utf-8") as input_file:
        entries = [json.loads(line) for line in input_file if line.strip()]
    if not any(entry.get("type") == "compaction" for entry in entries):
        raise SystemExit("successful retry did not persist a compaction entry")

server.shutdown()
server.server_close()
print("e2e: RPC compaction retries transient summarization errors with Pi events OK")
PY
