#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-responses-e2e.XXXXXX")
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

session_file="$tmp_dir/replay.jsonl"
request_file="$tmp_dir/request.json"
port_file="$tmp_dir/port"
output_file="$tmp_dir/output"
cwd=$(pwd)

printf '%s\n' \
    '{"type":"session","version":3,"id":"e2e-replay","timestamp":"2026-01-01T00:00:00.000Z","cwd":"'"$cwd"'"}' \
    '{"type":"message","id":"u1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"use the tool","timestamp":1}}' \
    '{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_foreign|abcdefghijklmnop+/=abcdefghijklmnop+/=abcdefghijklmnop+/=abcdefghijklmnop+/=","name":"read","arguments":{"path":"README.md"}}],"api":"openai-responses","provider":"github-copilot","model":"gpt-5.5","stopReason":"toolUse","timestamp":2}}' \
    '{"type":"message","id":"t1","parentId":"a1","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"toolResult","toolCallId":"call_foreign|abcdefghijklmnop+/=abcdefghijklmnop+/=abcdefghijklmnop+/=abcdefghijklmnop+/=","toolName":"read","content":[{"type":"text","text":"ok"}],"isError":false,"timestamp":3}}' \
    > "$session_file"

python3 - "$request_file" "$port_file" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

request_path, port_path = sys.argv[1:3]

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        with open(request_path, "wb") as output:
            output.write(body)
        stream = b"".join([
            b'data: {"type":"response.created","response":{"id":"resp_e2e"}}\n\n',
            b'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_e2e","phase":"final_answer","content":[]}}\n\n',
            b'data: {"type":"response.output_text.delta","output_index":0,"delta":"ok"}\n\n',
            b'data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_e2e","phase":"final_answer","content":[{"type":"output_text","text":"ok"}]}}\n\n',
            b'data: {"type":"response.completed","response":{"id":"resp_e2e","status":"completed","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}\n\n',
        ])
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(stream)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(stream)
        self.wfile.flush()

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w") as output:
    output.write(str(server.server_port))
server.handle_request()
PY
server_pid=$!

for _ in $(seq 1 100); do
    if [ -s "$port_file" ]; then break; fi
    sleep 0.01
done
if [ ! -s "$port_file" ]; then
    echo 'e2e: local Responses server did not start' >&2
    exit 1
fi
port=$(cat "$port_file")

if ! ADOU_CODING_AGENT_DIR="$tmp_dir/agent" \
    ADOU_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --provider openai --model gpt-5.1-codex --thinking off \
    --base-url "http://127.0.0.1:$port/v1" --api-key e2e-key \
    --mode json --no-context-files --session "$session_file" \
    'say hi' > "$output_file" 2>&1; then
    echo 'e2e: Responses replay command failed' >&2
    cat "$output_file" >&2
    exit 1
fi

wait "$server_pid"
server_pid=''

if ! rg -F '"type":"function_call"' "$request_file" >/dev/null; then
    echo 'e2e: Responses request did not contain the replayed function call' >&2
    exit 1
fi
if ! rg -F '"call_id":"call_foreign"' "$request_file" >/dev/null; then
    echo 'e2e: Responses request did not normalize the call id' >&2
    exit 1
fi
if ! rg -F '"id":"fc_wahzbi1nji4hg"' "$request_file" >/dev/null; then
    echo 'e2e: Responses request did not hash the foreign item id' >&2
    exit 1
fi
if ! rg -F '"type":"function_call_output"' "$request_file" >/dev/null; then
    echo 'e2e: Responses request did not replay the tool result' >&2
    exit 1
fi
if ! rg -F '"reasoning":{"effort":"none"}' "$request_file" >/dev/null; then
    echo 'e2e: Responses request did not map thinking off to none' >&2
    exit 1
fi
if ! rg -F -- '- read: Read file contents' "$request_file" >/dev/null || \
   ! rg -F -- '- bash: Execute bash commands (ls, grep, find, etc.)' "$request_file" >/dev/null || \
   ! rg -F -- '- edit: Make precise file edits with exact text replacement, including multiple disjoint edits in one call' "$request_file" >/dev/null || \
   ! rg -F -- '- write: Create or overwrite files' "$request_file" >/dev/null; then
    echo 'e2e: Responses request did not advertise Pi default coding tools' >&2
    exit 1
fi
if rg -F -- '- grep:' "$request_file" >/dev/null || \
   rg -F -- '- find:' "$request_file" >/dev/null || \
   rg -F -- '- ls:' "$request_file" >/dev/null; then
    echo 'e2e: Responses request advertised opt-in tools in the default prompt' >&2
    exit 1
fi
if rg -F '"include"' "$request_file" >/dev/null; then
    echo 'e2e: Responses request unexpectedly included encrypted reasoning when thinking is off' >&2
    exit 1
fi
if ! rg -F '"delta":"ok"' "$output_file" >/dev/null; then
    echo 'e2e: Responses output did not reach the JSON event stream' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! python3 - "$output_file" <<'PY'
import json
import sys

for line in open(sys.argv[1], encoding="utf-8"):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    assistant_event = event.get("assistantMessageEvent")
    if not isinstance(assistant_event, dict):
        continue
    partial = assistant_event.get("partial")
    if (
        assistant_event.get("type") in ("text_start", "text_end")
        and isinstance(partial, dict)
        and partial.get("stopReason") == "stop"
    ):
        raise SystemExit(0)

raise SystemExit(1)
PY
then
    echo 'e2e: Responses final_answer phase did not update the partial stop reason' >&2
    cat "$output_file" >&2
    exit 1
fi

echo 'e2e: Responses foreign tool id replay OK'
