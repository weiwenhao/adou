#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary")
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-tool-edge-e2e.XXXXXX")
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
fixture_dir = os.path.join(root, "fixtures")
os.mkdir(fixture_dir)
with open(os.path.join(fixture_dir, "first.txt"), "w", encoding="utf-8") as output:
    output.write("match one\nother\n")
with open(os.path.join(fixture_dir, "second.txt"), "w", encoding="utf-8") as output:
    output.write("match two\nother\n")
with open(os.path.join(root, "value.txt"), "w", encoding="utf-8") as output:
    output.write("not a directory target\n")

def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()

def tool_response(response_number, name, call_id, arguments):
    response_id = "resp_edge_%d" % response_number
    item_id = "fc_edge_%d" % response_number
    return b"".join([
        event({"type": "response.created", "response": {"id": response_id}}),
        event({"type": "response.output_item.added", "output_index": 0, "item": {
            "type": "function_call", "id": item_id, "call_id": call_id,
            "name": name, "arguments": ""
        }}),
        event({"type": "response.function_call_arguments.delta", "output_index": 0, "delta": arguments}),
        event({"type": "response.function_call_arguments.done", "output_index": 0, "arguments": arguments}),
        event({"type": "response.output_item.done", "output_index": 0, "item": {
            "type": "function_call", "id": item_id, "call_id": call_id,
            "name": name, "arguments": arguments
        }}),
        event({"type": "response.completed", "response": {
            "id": response_id, "status": "completed",
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}
        }}),
    ])

def final_response():
    return b"".join([
        event({"type": "response.created", "response": {"id": "resp_edge_4"}}),
        event({"type": "response.output_item.added", "output_index": 0, "item": {
            "type": "message", "id": "msg_edge_4", "phase": "final_answer", "content": []
        }}),
        event({"type": "response.output_text.delta", "output_index": 0, "delta": "edge-ok"}),
        event({"type": "response.output_item.done", "output_index": 0, "item": {
            "type": "message", "id": "msg_edge_4", "phase": "final_answer",
            "content": [{"type": "output_text", "text": "edge-ok"}]
        }}),
        event({"type": "response.completed", "response": {
            "id": "resp_edge_4", "status": "completed",
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
        if Handler.requests == 1:
            stream = tool_response(1, "grep", "call_edge_grep", '{"pattern":"match","path":"fixtures","limit":0}')
        elif Handler.requests == 2:
            stream = tool_response(2, "find", "call_edge_find", '{"pattern":"fixtures/**/*.txt"}')
        elif Handler.requests == 3:
            stream = tool_response(3, "ls", "call_edge_ls", '{"path":"value.txt"}')
        else:
            stream = final_response()
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
for _ in range(4):
    server.handle_request()
PY
server_pid=$!

for _ in $(seq 1 100); do
    if [ -s "$port_file" ]; then break; fi
    sleep 0.01
done
if [ ! -s "$port_file" ]; then
    echo 'e2e: local tool-edge server did not start' >&2
    exit 1
fi
port=$(cat "$port_file")

if ! (
    cd "$tmp_dir"
    PI_CODING_AGENT_DIR="$tmp_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --provider openai --model gpt-5.1-codex --thinking off \
    --base-url "http://127.0.0.1:$port/v1" --api-key e2e-key \
    --mode json --no-context-files --no-session --tools grep,find,ls 'check tool edge behavior'
) > "$output_file" 2>&1; then
    echo 'e2e: tool-edge command failed' >&2
    cat "$output_file" >&2
    exit 1
fi

wait "$server_pid"
server_pid=''

if [ "$(cat "$request_count_file")" != 4 ]; then
    echo 'e2e: tool edge cases did not produce three tool turns and a final answer' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! (rg -F 'first.txt:1: match one' "$output_file" >/dev/null || \
      rg -F 'second.txt:1: match two' "$output_file" >/dev/null) || \
   (rg -F 'first.txt:1: match one' "$output_file" >/dev/null && \
    rg -F 'second.txt:1: match two' "$output_file" >/dev/null); then
    echo 'e2e: grep limit=0 did not clamp to one global match' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! rg -F 'fixtures/first.txt' "$output_file" >/dev/null || \
   ! rg -F 'fixtures/second.txt' "$output_file" >/dev/null; then
    echo 'e2e: find glob was not passed through to the searcher' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! rg -F 'Not a directory:' "$output_file" | rg -F '/value.txt' >/dev/null; then
    echo 'e2e: ls did not reject a regular file path' >&2
    cat "$output_file" >&2
    exit 1
fi
if ! rg -F '"delta":"edge-ok"' "$output_file" >/dev/null; then
    echo 'e2e: final response was not emitted after tool errors' >&2
    cat "$output_file" >&2
    exit 1
fi

echo 'e2e: grep, find, and ls Pi edge behavior OK'
