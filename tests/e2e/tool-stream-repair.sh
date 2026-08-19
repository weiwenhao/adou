#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-tool-repair-e2e.XXXXXX")
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

port_file="$tmp_dir/port"
request_count_file="$tmp_dir/request-count"
output_file="$tmp_dir/output"

python3 - "$port_file" "$request_count_file" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_path, count_path = sys.argv[1:3]
partial_args = '{"path":"main.n'

def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()

def first_response():
    return b"".join([
        event({"type": "response.created", "response": {"id": "resp_tool_1"}}),
        event({"type": "response.output_item.added", "output_index": 0, "item": {
            "type": "function_call", "id": "fc_repair", "call_id": "call_repair",
            "name": "read", "arguments": ""
        }}),
        event({"type": "response.function_call_arguments.delta", "output_index": 0, "delta": partial_args}),
        event({"type": "response.function_call_arguments.done", "output_index": 0, "arguments": partial_args}),
        event({"type": "response.output_item.done", "output_index": 0, "item": {
            "type": "function_call", "id": "fc_repair", "call_id": "call_repair",
            "name": "read", "arguments": partial_args
        }}),
        event({"type": "response.completed", "response": {
            "id": "resp_tool_1", "status": "completed",
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}
        }}),
    ])

def second_response():
    return b"".join([
        event({"type": "response.created", "response": {"id": "resp_tool_2"}}),
        event({"type": "response.output_item.added", "output_index": 0, "item": {
            "type": "message", "id": "msg_tool_2", "phase": "final_answer", "content": []
        }}),
        event({"type": "response.output_text.delta", "output_index": 0, "delta": "repaired"}),
        event({"type": "response.output_item.done", "output_index": 0, "item": {
            "type": "message", "id": "msg_tool_2", "phase": "final_answer",
            "content": [{"type": "output_text", "text": "repaired"}]
        }}),
        event({"type": "response.completed", "response": {
            "id": "resp_tool_2", "status": "completed",
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}
        }}),
    ])

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests = 0

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        Handler.requests += 1
        with open(count_path, "w", encoding="ascii") as output:
            output.write(str(Handler.requests))
        stream = first_response() if Handler.requests == 1 else second_response()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(stream)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(stream)
        self.wfile.flush()

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w", encoding="ascii") as output:
    output.write(str(server.server_port))
for _ in range(2):
    server.handle_request()
PY
server_pid=$!

for _ in $(seq 1 100); do
    if [ -s "$port_file" ]; then break; fi
    sleep 0.01
done
if [ ! -s "$port_file" ]; then
    echo 'e2e: local tool-stream server did not start' >&2
    exit 1
fi
port=$(cat "$port_file")

if ! ADOU_CODING_AGENT_DIR="$tmp_dir/agent" \
    ADOU_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --provider openai --model gpt-5.1-codex --thinking off \
    --base-url "http://127.0.0.1:$port/v1" --api-key e2e-key \
    --mode json --no-context-files --no-session 'read main.n' > "$output_file" 2>&1; then
    echo 'e2e: tool-stream repair command failed' >&2
    cat "$output_file" >&2
    exit 1
fi

wait "$server_pid"
server_pid=''

if [ "$(cat "$request_count_file")" != 2 ]; then
    echo 'e2e: repaired tool call did not trigger a follow-up model turn' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! rg -F '"delta":"repaired"' "$output_file" >/dev/null; then
    echo 'e2e: follow-up response was not emitted after repaired tool arguments' >&2
    cat "$output_file" >&2
    exit 1
fi

echo 'e2e: incomplete tool arguments repaired and executed OK'
