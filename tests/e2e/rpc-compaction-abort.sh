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
provider_ready = threading.Event()
release_provider = threading.Event()


def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()


def summary_response():
    return b"".join(
        [
            event(
                {
                    "id": "summary-1",
                    "choices": [
                        {"delta": {"role": "assistant", "content": "## Goal\ncompact"}, "finish_reason": None}
                    ],
                }
            ),
            event(
                {
                    "id": "summary-1",
                    "choices": [{"delta": {}, "finish_reason": "stop"}],
                }
            ),
            event(
                {
                    "id": "summary-1",
                    "choices": [],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 8, "total_tokens": 18},
                }
            ),
            b"data: [DONE]\n\n",
        ]
    )


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
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            provider_ready.set()
            # Keep the prompt turn active.  Adou must close this request when
            # compact arrives; releasing it before then would let the prompt
            # finish normally and would not exercise Pi's abort-before-compact
            # contract.
            release_provider.wait(8)
            try:
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except OSError:
                pass
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


with tempfile.TemporaryDirectory(prefix="adou-rpc-compaction-abort-") as root:
    cwd = os.getcwd()
    session_file = os.path.join(root, "seed.jsonl")
    os.makedirs(os.path.dirname(session_file), exist_ok=True)
    seed = [
        {
            "type": "session",
            "version": 3,
            "id": "rpc-compaction-abort",
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
            "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
            "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
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
        "rpc-compaction-key",
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
        proc.stdin.write(json.dumps({"id": "prompt", "type": "prompt", "message": "active request"}) + "\n")
        proc.stdin.flush()
        if read_until(
            proc,
            seen,
            lambda item: item.get("type") == "response" and item.get("id") == "prompt",
            5,
        ) is None:
            raise SystemExit("did not receive prompt acknowledgement")
        if not provider_ready.wait(5):
            raise SystemExit("prompt provider request did not become active")

        proc.stdin.write(
            json.dumps({"id": "compact", "type": "compact", "customInstructions": "preserve the goal"}) + "\n"
        )
        proc.stdin.flush()
        if read_until(
            proc,
            seen,
            lambda item: item.get("type") == "response" and item.get("id") == "compact",
            10,
        ) is None:
            raise SystemExit("did not receive compact response")

        compact_response_index = next(
            (index for index, item in enumerate(seen) if item.get("type") == "response" and item.get("id") == "compact"),
            None,
        )
        session_end_index = next(
            (index for index, item in enumerate(seen) if item.get("type") == "session_end"),
            None,
        )
        if session_end_index is None or compact_response_index is None or compact_response_index <= session_end_index:
            raise SystemExit(f"compact response was emitted before aborted prompt ended: {seen!r}")
        if not next(item.get("success") is True for item in seen if item.get("type") == "response" and item.get("id") == "compact"):
            raise SystemExit(f"compact response failed: {seen!r}")
        if not any(item.get("type") == "compaction_start" and item.get("reason") == "manual" for item in seen):
            raise SystemExit(f"manual compaction_start event missing: {seen!r}")
        compaction_end = next((item for item in seen if item.get("type") == "compaction_end"), None)
        if not compaction_end or compaction_end.get("errorMessage", "") != "":
            raise SystemExit(f"successful compaction_end event missing: {seen!r}")
        if compaction_end.get("aborted") is not False or compaction_end.get("willRetry") is not False:
            raise SystemExit(f"Pi compaction terminal flags missing: {compaction_end!r}")
        result = compaction_end.get("result")
        if not isinstance(result, dict) or not result.get("summary") or "tokensBefore" not in result or "estimatedTokensAfter" not in result:
            raise SystemExit(f"Pi nested compaction result missing: {compaction_end!r}")
        if "summary" in compaction_end or "tokensBefore" in compaction_end:
            raise SystemExit(f"compaction result was flattened instead of nested: {compaction_end!r}")

        with open(session_file, encoding="utf-8") as session:
            entries = [json.loads(line) for line in session if line.strip()]
        if not any(entry.get("type") == "compaction" for entry in entries):
            raise SystemExit("compaction entry was not persisted")
        if Provider.requests != 2:
            raise SystemExit(f"expected prompt abort followed by summary request, got {Provider.requests} requests")
    finally:
        release_provider.set()
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=3)
        if proc.returncode != 0:
            error = proc.stderr.read()
            if error:
                sys.stderr.write(error)
        server.shutdown()

print("e2e: RPC compaction aborts active prompt before summarizing OK")
PY
