#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary")
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-nfd-read-e2e.XXXXXX")
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

python3 - "$tmp_dir" "$port_file" "$request_count_file" <<'PY' &
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

root, port_path, count_path = sys.argv[1:4]
nfd_name = "filee\u0301.txt"
with open(os.path.join(root, nfd_name), "w", encoding="utf-8") as output:
    output.write("nfd-content\n")

def event(value):
    return ("data: " + json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n\n").encode("utf-8")

def first_response():
    arguments = '{"path":"fileé.txt"}'
    return b"".join([
        event({"type": "response.created", "response": {"id": "resp_nfd_1"}}),
        event({"type": "response.output_item.added", "output_index": 0, "item": {
            "type": "function_call", "id": "fc_nfd", "call_id": "call_nfd",
            "name": "read", "arguments": ""
        }}),
        event({"type": "response.function_call_arguments.delta", "output_index": 0, "delta": arguments}),
        event({"type": "response.function_call_arguments.done", "output_index": 0, "arguments": arguments}),
        event({"type": "response.output_item.done", "output_index": 0, "item": {
            "type": "function_call", "id": "fc_nfd", "call_id": "call_nfd",
            "name": "read", "arguments": arguments
        }}),
        event({"type": "response.completed", "response": {
            "id": "resp_nfd_1", "status": "completed",
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}
        }}),
    ])

def second_response():
    return b"".join([
        event({"type": "response.created", "response": {"id": "resp_nfd_2"}}),
        event({"type": "response.output_item.added", "output_index": 0, "item": {
            "type": "message", "id": "msg_nfd_2", "phase": "final_answer", "content": []
        }}),
        event({"type": "response.output_text.delta", "output_index": 0, "delta": "nfd-ok"}),
        event({"type": "response.output_item.done", "output_index": 0, "item": {
            "type": "message", "id": "msg_nfd_2", "phase": "final_answer",
            "content": [{"type": "output_text", "text": "nfd-ok"}]
        }}),
        event({"type": "response.completed", "response": {
            "id": "resp_nfd_2", "status": "completed",
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
    echo 'e2e: local NFD server did not start' >&2
    exit 1
fi
port=$(cat "$port_file")

if ! (
    cd "$tmp_dir"
    PI_CODING_AGENT_DIR="$tmp_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --provider openai --model gpt-5.1-codex --thinking off \
    --base-url "http://127.0.0.1:$port/v1" --api-key e2e-key \
    --mode json --no-context-files --no-session 'read the accented file'
) > "$output_file" 2>&1; then
    echo 'e2e: NFD read command failed' >&2
    cat "$output_file" >&2
    exit 1
fi

wait "$server_pid"
server_pid=''

if [ "$(cat "$request_count_file")" != 2 ]; then
    echo 'e2e: NFD read did not trigger a follow-up model turn' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! rg -F 'nfd-content' "$output_file" >/dev/null; then
    echo 'e2e: read result did not contain the NFD fixture content' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! rg -F '"delta":"nfd-ok"' "$output_file" >/dev/null; then
    echo 'e2e: follow-up response after NFD read was not emitted' >&2
    cat "$output_file" >&2
    exit 1
fi

echo 'e2e: Pi-compatible NFD read path OK'
