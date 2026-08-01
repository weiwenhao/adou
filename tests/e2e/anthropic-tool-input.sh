#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-anthropic-tool-input-e2e.XXXXXX")
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

def frame(event_type, value):
    return ("event: " + event_type + "\ndata: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()

def first_response():
    # The initial input is visible before any input_json_delta arrives. The
    # later delta supplies the complete executable arguments for this turn.
    return b"".join([
        frame("message_start", {"type": "message_start", "message": {
            "id": "msg_anthropic_1", "usage": {"input_tokens": 1, "output_tokens": 0}
        }}),
        frame("content_block_start", {"type": "content_block_start", "index": 0,
            "content_block": {"type": "tool_use", "id": "tool_initial", "name": "read",
                "input": {"marker": "initial", "path": "main.n"}}}),
        frame("content_block_delta", {"type": "content_block_delta", "index": 0,
            "delta": {"type": "input_json_delta", "partial_json": '{"path":"main.n"}'}}),
        frame("content_block_stop", {"type": "content_block_stop", "index": 0}),
        frame("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use"},
            "usage": {"output_tokens": 1}}),
        frame("message_stop", {"type": "message_stop"}),
    ])

def second_response():
    return b"".join([
        frame("message_start", {"type": "message_start", "message": {
            "id": "msg_anthropic_2", "usage": {"input_tokens": 1, "output_tokens": 0}
        }}),
        frame("content_block_start", {"type": "content_block_start", "index": 0,
            "content_block": {"type": "text", "text": ""}}),
        frame("content_block_delta", {"type": "content_block_delta", "index": 0,
            "delta": {"type": "text_delta", "text": "done"}}),
        frame("content_block_stop", {"type": "content_block_stop", "index": 0}),
        frame("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
            "usage": {"output_tokens": 1}}),
        frame("message_stop", {"type": "message_stop"}),
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
    echo 'e2e: local Anthropic server did not start' >&2
    exit 1
fi
port=$(cat "$port_file")

if ! PI_CODING_AGENT_DIR="$tmp_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --provider anthropic --model claude-sonnet-4-5 --thinking off \
    --base-url "http://127.0.0.1:$port/v1" --api-key e2e-key \
    --mode json --no-context-files --no-session 'read main.n' > "$output_file" 2>&1; then
    echo 'e2e: Anthropic initial tool-input command failed' >&2
    cat "$output_file" >&2
    exit 1
fi

wait "$server_pid"
server_pid=''

if [ "$(cat "$request_count_file")" != 2 ]; then
    echo 'e2e: initial tool-input stream did not trigger a follow-up model turn' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! rg -F '"marker":"initial"' "$output_file" >/dev/null; then
    echo 'e2e: content_block_start input was not preserved in the tool-call start event' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! rg -F '"delta":"done"' "$output_file" >/dev/null; then
    echo 'e2e: follow-up Anthropic response was not emitted' >&2
    cat "$output_file" >&2
    exit 1
fi

echo 'e2e: Anthropic initial tool input preserved OK'
