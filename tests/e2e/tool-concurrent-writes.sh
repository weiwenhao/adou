#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary")
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-concurrent-writes-e2e.XXXXXX")
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
target = "shared.txt"
size = 64 * 1024

def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()

def write_item(index, call_id, content):
    item_id = "fc_concurrent_%d" % index
    arguments = json.dumps({"path": target, "content": content}, separators=(",", ":"))
    return b"".join([
        event({"type": "response.output_item.added", "output_index": index, "item": {
            "type": "function_call", "id": item_id, "call_id": call_id,
            "name": "write", "arguments": ""
        }}),
        event({"type": "response.function_call_arguments.delta", "output_index": index, "delta": arguments}),
        event({"type": "response.function_call_arguments.done", "output_index": index, "arguments": arguments}),
        event({"type": "response.output_item.done", "output_index": index, "item": {
            "type": "function_call", "id": item_id, "call_id": call_id,
            "name": "write", "arguments": arguments
        }}),
    ])

def first_response():
    # Large, distinct payloads make an unlocked pair of writes observable as
    # a mixed file while a mutation queue leaves one complete payload intact.
    return b"".join([
        event({"type": "response.created", "response": {"id": "resp_concurrent_1"}}),
        write_item(0, "call_concurrent_a", "A" * size),
        write_item(1, "call_concurrent_b", "B" * size),
        event({"type": "response.completed", "response": {
            "id": "resp_concurrent_1", "status": "completed",
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}
        }}),
    ])

def final_response():
    return b"".join([
        event({"type": "response.created", "response": {"id": "resp_concurrent_2"}}),
        event({"type": "response.output_item.added", "output_index": 0, "item": {
            "type": "message", "id": "msg_concurrent_2", "phase": "final_answer", "content": []
        }}),
        event({"type": "response.output_text.delta", "output_index": 0, "delta": "concurrent-ok"}),
        event({"type": "response.output_item.done", "output_index": 0, "item": {
            "type": "message", "id": "msg_concurrent_2", "phase": "final_answer",
            "content": [{"type": "output_text", "text": "concurrent-ok"}]
        }}),
        event({"type": "response.completed", "response": {
            "id": "resp_concurrent_2", "status": "completed",
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
        stream = first_response() if Handler.requests == 1 else final_response()
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
    echo 'e2e: local concurrent-write server did not start' >&2
    exit 1
fi
port=$(cat "$port_file")

if ! (
    cd "$tmp_dir"
    PI_CODING_AGENT_DIR="$tmp_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --provider openai --model gpt-5.1-codex --thinking off \
    --base-url "http://127.0.0.1:$port/v1" --api-key e2e-key \
    --mode json --no-context-files --no-session --tools write 'write concurrently'
) > "$output_file" 2>&1; then
    echo 'e2e: concurrent write command failed' >&2
    cat "$output_file" >&2
    exit 1
fi

wait "$server_pid"
server_pid=''

if [ "$(cat "$request_count_file")" != 2 ]; then
    echo 'e2e: concurrent write tool calls did not produce a follow-up model turn' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! rg -F '"text":"concurrent-ok"' "$output_file" >/dev/null; then
    echo 'e2e: final response was not emitted after concurrent writes' >&2
    cat "$output_file" >&2
    exit 1
fi
python3 - "$tmp_dir/shared.txt" <<'PY'
import sys

value = open(sys.argv[1], "r", encoding="ascii").read()
if value not in ("A" * (64 * 1024), "B" * (64 * 1024)):
    raise SystemExit("shared write was interleaved or incomplete")
PY

echo 'e2e: concurrent writes serialize same-file mutations OK'
