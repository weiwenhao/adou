#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-initial-messages-e2e.XXXXXX")
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
count_file="$tmp_dir/count"
output_file="$tmp_dir/output"
file_path="$tmp_dir/context.txt"
image_path="$tmp_dir/pixel.png"
printf '%s' 'FILE_CONTENT' > "$file_path"
python3 - "$image_path" <<'PY'
import base64
import sys

open(sys.argv[1], "wb").write(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
))
PY

python3 - "$port_file" "$count_file" "$tmp_dir" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_path, count_path, request_dir = sys.argv[1:4]

def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests = 0

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        Handler.requests += 1
        number = Handler.requests
        with open(f"{request_dir}/request-{number}.json", "wb") as output:
            output.write(body)
        with open(count_path, "w", encoding="ascii") as output:
            output.write(str(number))
        answer = f"answer-{number}"
        stream = b"".join([
            event({"id": f"initial-{number}", "choices": [{"delta": {
                "role": "assistant", "content": answer
            }, "finish_reason": None}]}),
            event({"id": f"initial-{number}", "choices": [{"delta": {}, "finish_reason": "stop"}]}),
            event({"id": f"initial-{number}", "choices": [], "usage": {
                "prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2
            }}),
            b"data: [DONE]\n\n",
        ])
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(stream)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(stream)
        self.wfile.flush()

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w", encoding="utf-8") as output:
    output.write(str(server.server_port))
for _ in range(6):
    server.handle_request()
PY
server_pid=$!

for _ in $(seq 1 100); do
    if [ -s "$port_file" ]; then break; fi
    sleep 0.01
done
if [ ! -s "$port_file" ]; then
    echo 'e2e: local Chat Completions server did not start' >&2
    exit 1
fi
port=$(cat "$port_file")

if ! ADOU_CODING_AGENT_DIR="$tmp_dir/agent-file" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-file" \
    "$binary" --provider deepseek --model deepseek-v4-flash --thinking off \
    --base-url "http://127.0.0.1:$port/v1" --api-key e2e-key \
    -p --no-context-files --no-session "@$file_path" first second > "$output_file" 2>&1; then
    echo 'e2e: @file initial-message command failed' >&2
    cat "$output_file" >&2
    exit 1
fi
if [ "$(cat "$output_file")" != 'answer-2' ]; then
    echo 'e2e: print mode did not return only the last sequential response' >&2
    cat "$output_file" >&2
    exit 1
fi

stdin_output="$tmp_dir/stdin-output"
if ! printf '%b' '  STDIN_CONTENT  \n' | \
    ADOU_CODING_AGENT_DIR="$tmp_dir/agent-stdin" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-stdin" \
    "$binary" --provider deepseek --model deepseek-v4-flash --thinking off \
    --base-url "http://127.0.0.1:$port/v1" --api-key e2e-key \
    --print --no-context-files --no-session first second > "$stdin_output" 2>&1; then
    echo 'e2e: piped-stdin initial-message command failed' >&2
    cat "$stdin_output" >&2
    exit 1
fi
if [ "$(cat "$stdin_output")" != 'answer-4' ]; then
    echo 'e2e: piped stdin did not return only the last sequential response' >&2
    cat "$stdin_output" >&2
    exit 1
fi

# Pi resolves a non-TTY invocation with a positional prompt to print mode,
# even without an explicit -p.  The output must be the final assistant text,
# not Adou's static TUI transcript.
direct_output="$tmp_dir/direct-output"
if ! ADOU_CODING_AGENT_DIR="$tmp_dir/agent-direct" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-direct" \
    "$binary" --provider deepseek --model deepseek-v4-flash --thinking off \
    --base-url "http://127.0.0.1:$port/v1" --api-key e2e-key \
    --no-context-files --no-session direct-prompt > "$direct_output" 2>&1; then
    echo 'e2e: direct positional prompt one-shot command failed' >&2
    cat "$direct_output" >&2
    exit 1
fi
if [ "$(cat "$direct_output")" != 'answer-5' ]; then
    echo 'e2e: non-TTY positional prompt did not use Pi print-mode output' >&2
    cat "$direct_output" >&2
    exit 1
fi

image_output="$tmp_dir/image-output"
if ! ADOU_CODING_AGENT_DIR="$tmp_dir/agent-image" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-image" \
    "$binary" --provider deepseek --model deepseek-v4-flash --thinking off \
    --base-url "http://127.0.0.1:$port/v1" --api-key e2e-key \
    --print --no-context-files --no-session "@$image_path" describe > "$image_output" 2>&1; then
    echo 'e2e: @image initial-message command failed' >&2
    cat "$image_output" >&2
    exit 1
fi
if [ "$(cat "$image_output")" != 'answer-6' ]; then
    echo 'e2e: @image did not complete the provider round trip' >&2
    cat "$image_output" >&2
    exit 1
fi

wait "$server_pid"
server_pid=''

python3 - "$count_file" "$tmp_dir" <<'PY'
import json
import sys

count_path, request_dir = sys.argv[1:3]
if open(count_path, encoding="ascii").read().strip() != "6":
    raise SystemExit("expected six model requests including one image prompt")

def user_contents(number):
    body = json.load(open(f"{request_dir}/request-{number}.json", encoding="utf-8"))
    return [item.get("content", "") for item in body.get("messages", []) if item.get("role") == "user"]

file_first = user_contents(1)
file_second = user_contents(2)
stdin_first = user_contents(3)
stdin_second = user_contents(4)
direct = user_contents(5)
image = user_contents(6)

if not file_first or "FILE_CONTENT" not in str(file_first[-1]) or "first" not in str(file_first[-1]):
    raise SystemExit(f"@file content was not prefixed to the first prompt: {file_first!r}")
if file_second[-1] != "second" or any("first second" in str(value) for value in file_second):
    raise SystemExit(f"CLI messages were merged instead of sent sequentially: {file_second!r}")
if not stdin_first or stdin_first[-1] != "STDIN_CONTENTfirst":
    raise SystemExit(f"stdin content was not prefixed to the first prompt: {stdin_first!r}")
if stdin_second[-1] != "second" or any("first second" in str(value) for value in stdin_second):
    raise SystemExit(f"piped CLI messages were merged instead of sent sequentially: {stdin_second!r}")
if not direct or direct[-1] != "direct-prompt":
    raise SystemExit(f"direct positional prompt was not sent as one request: {direct!r}")
if not image or not isinstance(image[-1], list):
    raise SystemExit(f"@image user content was not multimodal: {image!r}")
image_blocks = image[-1]
if not any(block.get("type") == "text" and "pixel.png" in block.get("text", "") for block in image_blocks):
    raise SystemExit(f"@image file reference missing from text block: {image_blocks!r}")
if not any(block.get("type") == "image_url" and block.get("image_url", {}).get("url", "").startswith("data:image/png;base64,") for block in image_blocks):
    raise SystemExit(f"@image data block missing from request: {image_blocks!r}")
PY

rpc_error="$tmp_dir/rpc-error"
if ADOU_CODING_AGENT_DIR="$tmp_dir/agent-rpc" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-rpc" \
    "$binary" --mode rpc --no-session "@$file_path" > "$rpc_error" 2>&1; then
    echo 'e2e: RPC accepted an @file argument' >&2
    cat "$rpc_error" >&2
    exit 1
fi
if ! rg -F '@file arguments are not supported in RPC mode' "$rpc_error" >/dev/null; then
    echo 'e2e: RPC @file rejection did not match Pi' >&2
    cat "$rpc_error" >&2
    exit 1
fi

echo 'e2e: Pi initial message composition and sequential prompts OK'
