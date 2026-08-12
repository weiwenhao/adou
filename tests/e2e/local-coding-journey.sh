#!/bin/sh
set -eu

# Local deterministic coding journey (offline, no external network):
#
#   1. Headless round 1 against an embedded OpenAI-completions mock: the
#      model issues read -> edit -> bash tool calls, the tools execute for
#      real inside an isolated mktemp workspace, and the run finishes with a
#      final answer.  The session is persisted as Pi v3 JSONL.
#   2. A minimal PTY bridge then reopens the SAME session in the TUI with
#      --offline and asserts the round-1 history renders (resume path).
#   3. Headless round 2 resumes the same session (--session <file>): the
#      mock receives a second request whose history must contain the round-1
#      tool results and the edited file content, and replies accordingly.
#
# The PTY is deliberately limited to offline history rendering; the tool
# chain itself is driven headless in --mode json because scripted PTY input
# is flaky under the differential renderer (see docs/e2e-journey-matrix.md).
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi
# The Makefile passes a repo-relative ADOU_BIN; absolutize it so the cwd
# changes inside the journey (tool execution workspace) cannot break it.
binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary")

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-local-journey.XXXXXX")
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

work_dir="$tmp_dir/work"
session_dir="$tmp_dir/sessions"
req_dir="$tmp_dir/reqs"
mkdir -p "$work_dir" "$session_dir" "$req_dir"
printf 'hello' > "$work_dir/note.txt"

port_file="$tmp_dir/port"
history_check="$req_dir/history-check.txt"
round_one_out="$tmp_dir/round1.jsonl"
round_two_out="$tmp_dir/round2.jsonl"
round_one_err="$tmp_dir/round1.err"
round_two_err="$tmp_dir/round2.err"

python3 - "$req_dir" "$port_file" "$history_check" <<'PY' &
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

req_dir, port_path, history_check = sys.argv[1:4]
count = 0


def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()


def usage_chunk():
    return event({"usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})


def tool_stream(turn, name, call_id, arguments):
    return b"".join([
        event({"id": "chatcmpl_%d" % turn, "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]}),
        event({"id": "chatcmpl_%d" % turn, "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": call_id,
               "type": "function", "function": {"name": name, "arguments": arguments}}]}}]}),
        event({"id": "chatcmpl_%d" % turn, "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}),
        usage_chunk(),
        b"data: [DONE]\n\n",
    ])


def final_stream(turn, text):
    return b"".join([
        event({"id": "chatcmpl_%d" % turn, "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]}),
        event({"id": "chatcmpl_%d" % turn, "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {"content": text}}]}),
        event({"id": "chatcmpl_%d" % turn, "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}),
        usage_chunk(),
        b"data: [DONE]\n\n",
    ])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        global count
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        count += 1
        with open(os.path.join(req_dir, "req-%d.json" % count), "w", encoding="utf-8") as out:
            out.write(body)
        if count == 1:
            stream = tool_stream(1, "read", "call_journey_read_1", '{"path":"note.txt"}')
        elif count == 2:
            stream = tool_stream(2, "edit", "call_journey_edit_2",
                                 '{"path":"note.txt","edits":[{"oldText":"hello","newText":"hello world"}]}')
        elif count == 3:
            stream = tool_stream(3, "bash", "call_journey_bash_3",
                                 '{"command":"printf bash-ran > bash-marker"}')
        elif count == 4:
            stream = final_stream(4, "round one complete")
        elif count == 5:
            stream = tool_stream(5, "read", "call_journey_read_5", '{"path":"note.txt"}')
        else:
            # Round-2 request: the full round-1 history must be present,
            # including the edit result and the edited file content observed
            # by the round-2 read tool call.
            payload = json.loads(body)
            joined = json.dumps(payload.get("messages", []), separators=(",", ":"))
            ok = "hello world" in joined and "bash-ran" in joined and "round one complete" in joined
            with open(history_check, "w", encoding="ascii") as out:
                out.write("VERIFIED" if ok else "MISSING")
            stream = final_stream(6, "round two verified" if ok else "round two failed")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(stream)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(stream)
        self.wfile.flush()


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w", encoding="ascii") as out:
    out.write(str(server.server_port))
for _ in range(6):
    server.handle_request()
PY
server_pid=$!

for _ in $(seq 1 100); do
    if [ -s "$port_file" ]; then break; fi
    sleep 0.01
done
if [ ! -s "$port_file" ]; then
    echo 'e2e: local journey mock server did not start' >&2
    exit 1
fi
port=$(cat "$port_file")

if ! (
    cd "$work_dir"
    PI_CODING_AGENT_DIR="$tmp_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$session_dir" \
    "$binary" --provider deepseek --model deepseek-v4-flash --thinking off \
        --base-url "http://127.0.0.1:$port" --api-key e2e-journey-key \
        --mode json --no-context-files --max-tokens 1024 --max-retries 0 \
        --timeout-ms 30000 --session-dir "$session_dir" \
        'update the greeting in note.txt using the read, edit and bash tools'
) > "$round_one_out" 2> "$round_one_err"; then
    echo 'e2e: local journey round 1 failed' >&2
    cat "$round_one_out" >&2
    cat "$round_one_err" >&2
    exit 1
fi

if [ "$(ls "$req_dir"/req-*.json 2>/dev/null | wc -l | tr -d ' ')" != 4 ]; then
    echo 'e2e: local journey round 1 did not produce read/edit/bash/final turns' >&2
    cat "$round_one_out" >&2
    exit 1
fi
if [ "$(cat "$work_dir/note.txt")" != 'hello world' ]; then
    echo 'e2e: local journey edit tool did not modify the file' >&2
    exit 1
fi
if [ "$(cat "$work_dir/bash-marker")" != 'bash-ran' ]; then
    echo 'e2e: local journey bash tool did not execute' >&2
    exit 1
fi
if ! rg -F 'round one complete' "$round_one_out" >/dev/null; then
    echo 'e2e: local journey final answer missing after the tool chain' >&2
    cat "$round_one_out" >&2
    exit 1
fi
session_file=$(ls "$session_dir"/*.jsonl 2>/dev/null | head -n 1)
if [ -z "$session_file" ]; then
    echo 'e2e: local journey did not persist a session file' >&2
    exit 1
fi

# PTY resume bridge: reopen the SAME persisted session in the TUI offline and
# assert the round-1 history (final answer and tool chain) renders.
ADOU_BIN="$binary" SESSION_FILE="$session_file" AGENT_DIR="$tmp_dir/agent" \
    SESSION_DIR="$session_dir" python3 - <<'PY'
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import termios
import time

binary = os.environ["ADOU_BIN"]
session = os.environ["SESSION_FILE"]
agent_dir = os.environ["AGENT_DIR"]
os.makedirs(agent_dir, exist_ok=True)
open(os.path.join(agent_dir, ".adou-setup"), "w").close()
env = os.environ.copy()
env.update(
    {
        "PI_CODING_AGENT_DIR": agent_dir,
        "PI_CODING_AGENT_SESSION_DIR": os.environ["SESSION_DIR"],
    }
)

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(
        binary,
        [
            binary,
            "--offline",
            "--no-context-files",
            "--session",
            session,
            "--provider",
            "deepseek",
            "--model",
            "deepseek-v4-flash",
        ],
        env,
    )

output = bytearray()
status = None


def collect(until=None, timeout=4.0):
    global status
    deadline = time.time() + timeout
    while time.time() < deadline:
        if until is not None and until in output:
            return True
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                output.extend(os.read(fd, 65536))
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
        waited, child_status = os.waitpid(pid, os.WNOHANG)
        if waited:
            status = child_status
            break
    return until is not None and until in output


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    collect(timeout=1.0)
    if not collect(b"round one complete", timeout=6.0):
        raise SystemExit("PTY resume did not render the round-1 final answer")
    if not collect(b"Successfully replaced", timeout=4.0):
        raise SystemExit("PTY resume did not render the round-1 edit result")
    os.write(fd, b"/quit\r")
    collect(timeout=6.0)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
    exit_code = os.waitstatus_to_exitcode(status)
    if exit_code != 0:
        raise SystemExit(f"PTY resume TUI exited with status {exit_code}")
finally:
    try:
        os.close(fd)
    except OSError:
        pass
    if status is None:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            _, status = os.waitpid(pid, 0)
        except OSError:
            pass
PY

if ! (
    cd "$work_dir"
    PI_CODING_AGENT_DIR="$tmp_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$session_dir" \
    "$binary" --provider deepseek --model deepseek-v4-flash --thinking off \
        --base-url "http://127.0.0.1:$port" --api-key e2e-journey-key \
        --mode json --no-context-files --max-tokens 1024 --max-retries 0 \
        --timeout-ms 30000 --session "$session_file" \
        'read the file again and confirm'
) > "$round_two_out" 2> "$round_two_err"; then
    echo 'e2e: local journey round 2 (same session) failed' >&2
    cat "$round_two_out" >&2
    cat "$round_two_err" >&2
    exit 1
fi

if [ "$(ls "$req_dir"/req-*.json 2>/dev/null | wc -l | tr -d ' ')" != 6 ]; then
    echo 'e2e: local journey round 2 did not produce a follow-up turn' >&2
    cat "$round_two_out" >&2
    exit 1
fi
if [ ! -s "$history_check" ]; then
    echo 'e2e: local journey mock never verified the round-2 history' >&2
    exit 1
fi
if [ "$(cat "$history_check")" != 'VERIFIED' ]; then
    echo 'e2e: local journey round-2 request was missing round-1 tool results or file content' >&2
    exit 1
fi
if ! rg -F 'round two verified' "$round_two_out" >/dev/null; then
    echo 'e2e: local journey round-2 final answer missing' >&2
    cat "$round_two_out" >&2
    exit 1
fi

wait "$server_pid"
server_pid=''

python3 - "$session_file" <<'PY'
import json
import sys

path = sys.argv[1]
entries = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
messages = [entry["message"] for entry in entries if entry.get("type") == "message"]
expected = [
    ("user", None, None),
    ("assistant", "toolCall", None),
    ("toolResult", None, "read"),
    ("assistant", "toolCall", None),
    ("toolResult", None, "edit"),
    ("assistant", "toolCall", None),
    ("toolResult", None, "bash"),
    ("assistant", "text", None),
    ("user", None, None),
    ("assistant", "toolCall", None),
    ("toolResult", None, "read"),
    ("assistant", "text", None),
]
if len(messages) != len(expected):
    raise SystemExit(f"journey session message count mismatch: {len(messages)} vs {len(expected)}")
for index, (message, (role, kind, tool_name)) in enumerate(zip(messages, expected)):
    if message.get("role") != role:
        raise SystemExit(f"journey message {index}: expected role {role}, got {message!r}")
    if kind == "toolCall":
        blocks = message.get("content", [])
        if not (isinstance(blocks, list) and blocks and blocks[0].get("type") == "toolCall"):
            raise SystemExit(f"journey assistant message {index} is not a tool call: {message!r}")
    if kind == "text":
        blocks = message.get("content", [])
        if not (isinstance(blocks, list) and blocks and blocks[0].get("type") == "text"):
            raise SystemExit(f"journey assistant message {index} has no final text: {message!r}")
    if tool_name is not None:
        if message.get("toolName") != tool_name or message.get("isError") is not False:
            raise SystemExit(f"journey tool result {index} mismatch: {message!r}")
print("e2e: journey session JSONL order matches user/assistant/tool_call/tool_result OK")
PY

echo 'e2e: local coding journey (mock read/edit/bash, session resume, PTY bridge) OK'
