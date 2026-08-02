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

def response(text, total_tokens):
    return b"".join(
        [
            event({"id": "preprompt", "choices": [{"delta": {"role": "assistant", "content": text}, "finish_reason": None}]}),
            event({"id": "preprompt", "choices": [{"delta": {}, "finish_reason": "stop"}]}),
            event({"id": "preprompt", "choices": [], "usage": {"prompt_tokens": total_tokens, "completion_tokens": 1, "total_tokens": total_tokens + 1}}),
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
        # 1: first user turn; 2: compaction summary; 3: second user turn.
        if Provider.requests == 1:
            body = response("first answer " * 60, 95)
        elif Provider.requests == 2:
            body = response("## Goal\npre-prompt compaction\n\n## Progress\nretained", 20)
        else:
            body = response("second answer", 5)
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

with tempfile.TemporaryDirectory(prefix="adou-rpc-preprompt-compaction-") as root:
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
        "--no-session",
        "--no-context-files",
        "--provider",
        "deepseek",
        "--model",
        "deepseek-v4-flash",
        "--thinking",
        "off",
        "--context-window",
        "100",
        "--reserve-tokens",
        "10",
        "--keep-recent-tokens",
        "5",
        "--no-compaction",
        "--base-url",
        f"http://127.0.0.1:{port}",
        "--api-key",
        "rpc-preprompt-key",
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
        def read_until(predicate, timeout=12):
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
                    return
            raise SystemExit(f"timed out waiting for RPC event: {seen!r}")

        proc.stdin.write(json.dumps({"id": "first", "type": "prompt", "message": "first long turn"}) + "\n")
        proc.stdin.flush()
        read_until(lambda item: item.get("type") == "session_end")

        proc.stdin.write(json.dumps({"id": "enable", "type": "set_auto_compaction", "enabled": True}) + "\n")
        proc.stdin.flush()
        read_until(lambda item: item.get("type") == "response" and item.get("id") == "enable")

        start = len(seen)
        proc.stdin.write(json.dumps({"id": "second", "type": "prompt", "message": "second turn after an over-window response"}) + "\n")
        proc.stdin.flush()
        read_until(lambda item: item.get("type") == "session_end")
        second_events = seen[start:]
        compaction = next((i for i, item in enumerate(second_events) if item.get("type") == "compaction_start"), None)
        agent_start = next((i for i, item in enumerate(second_events) if item.get("type") == "agent_start"), None)
        if compaction is None or agent_start is None or compaction >= agent_start:
            raise SystemExit(f"pre-prompt compaction did not precede agent_start: {second_events!r}")
        if not any(item.get("type") == "response" and item.get("id") == "second" and item.get("success") is True for item in second_events):
            raise SystemExit(f"second prompt response missing: {second_events!r}")
        if Provider.requests != 3:
            raise SystemExit(f"expected first turn, summary, and second turn requests: {Provider.requests}")
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

print("e2e: RPC pre-prompt compaction precedes the next agent turn OK")
PY
