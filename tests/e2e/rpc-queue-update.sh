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
request_bodies = []

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
        body = self.rfile.read(length) if length else b"{}"
        payload = json.loads(body)
        with request_lock:
            request_count += 1
            current = request_count
            request_bodies.append(payload)
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
    agent_dir = os.path.join(root, "agent")
    home_dir = os.path.join(root, "home")
    prompt_dir = os.path.join(agent_dir, "prompts")
    os.makedirs(home_dir, exist_ok=True)
    os.makedirs(prompt_dir, exist_ok=True)

    def write_prompt(name, description, body):
        with open(os.path.join(prompt_dir, name + ".md"), "w", encoding="utf-8") as stream:
            stream.write(f"---\ndescription: {description}\n---\n\n{body}")

    write_prompt("start", "Start prompt", "START $@ OLD")
    write_prompt("steer", "Steering prompt", "STEER $@ OLD")
    write_prompt("follow", "Follow-up prompt", "FOLLOW $@ OLD")
    env = os.environ.copy()
    env.update({
        "HOME": home_dir,
        "ADOU_CODING_AGENT_DIR": agent_dir,
        "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
    })
    command = [
        binary, "--mode", "rpc", "--no-session", "--no-context-files",
        "--approve",
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

    def send(value):
        proc.stdin.write(json.dumps(value) + "\n")
        proc.stdin.flush()

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
        send({"id": "commands-before", "type": "get_commands"})
        read_until(lambda item: item.get("type") == "response" and item.get("id") == "commands-before", 5)
        commands_before = next(item for item in seen if item.get("id") == "commands-before")
        names_before = [item.get("name") for item in commands_before.get("data", {}).get("commands", [])]
        if set(names_before) != {"start", "steer", "follow"}:
            raise SystemExit(f"unexpected initial RPC resource commands: {commands_before!r}")

        # Change an existing template and add another after startup. Neither
        # discovery nor execution may see these files before an explicit
        # resource refresh/session rebind.
        write_prompt("start", "Changed start", "START $@ NEW")
        write_prompt("late", "Late prompt", "LATE $@")
        send({"id": "commands-after-disk", "type": "get_commands"})
        read_until(lambda item: item.get("type") == "response" and item.get("id") == "commands-after-disk", 5)
        commands_after = next(item for item in seen if item.get("id") == "commands-after-disk")
        names_after = [item.get("name") for item in commands_after.get("data", {}).get("commands", [])]
        if names_after != names_before:
            raise SystemExit(f"get_commands changed without resource refresh: {names_before!r} -> {names_after!r}")

        send({"id": "prompt", "type": "prompt", "message": "/start value"})
        read_until(lambda item: item.get("type") == "response" and item.get("id") == "prompt", 5)
        if not ready.wait(3):
            raise SystemExit("provider did not receive the initial request")
        with request_lock:
            first_request = request_bodies[0]
        first_users = [item.get("content") for item in first_request.get("messages", []) if item.get("role") == "user"]
        if not first_users or first_users[-1] != "START value OLD":
            raise SystemExit(f"RPC prompt did not execute the startup snapshot: {first_request!r}")

        send({"id": "steer", "type": "steer", "message": "/steer me"})
        send({"id": "follow", "type": "follow_up", "message": "/follow me"})
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
            (("STEER me OLD",), ()),
            (("STEER me OLD",), ("FOLLOW me OLD",)),
            ((), ("FOLLOW me OLD",)),
            ((), ()),
        ]
        for snapshot in expected:
            if snapshot not in snapshots:
                raise SystemExit(f"missing queue snapshot {snapshot!r}: {snapshots!r}")

        for text, snapshot in (("STEER me OLD", ((), ("FOLLOW me OLD",))), ("FOLLOW me OLD", ((), ()) )):
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

print("e2e: RPC resource snapshot execution and queue ordering OK")
PY
