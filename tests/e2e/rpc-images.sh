#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-rpc-images.XXXXXX")
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

python3 - "$tmp_dir/port" "$tmp_dir/request.json" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_path, request_path = sys.argv[1:]

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        open(request_path, "wb").write(body)
        def event(value):
            return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()
        stream = b"".join([
            event({"id":"rpc-image","choices":[{"delta":{"role":"assistant","content":"IMAGE_OK"},"finish_reason":None}]}),
            event({"id":"rpc-image","choices":[{"delta":{},"finish_reason":"stop"}]}),
            b"data: [DONE]\n\n",
        ])
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(stream)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(stream)

server = HTTPServer(("127.0.0.1", 0), Handler)
open(port_path, "w", encoding="ascii").write(str(server.server_port))
server.handle_request()
PY
server_pid=$!

for _ in $(seq 1 100); do
    if [ -s "$tmp_dir/port" ]; then break; fi
    sleep 0.01
done
port=$(cat "$tmp_dir/port")

printf '%s\n' '{"id":"image","type":"prompt","message":"describe","images":[{"type":"image","mimeType":"image/png","data":"aW1hZ2U="}]}' \
  | ADOU_CODING_AGENT_DIR="$tmp_dir/agent" ADOU_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --mode rpc --no-context-files --provider deepseek --model deepseek-v4-flash \
      --thinking off --base-url "http://127.0.0.1:$port/v1" --api-key rpc-image-key \
      > "$tmp_dir/output.jsonl"

wait "$server_pid"
server_pid=''

python3 - "$tmp_dir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
request = json.loads((root / "request.json").read_text())
user = [item for item in request.get("messages", []) if item.get("role") == "user"][-1]
blocks = user.get("content")
if not isinstance(blocks, list) or not any(item.get("type") == "image_url" for item in blocks):
    raise SystemExit(f"RPC image did not reach provider request: {user!r}")

output = [json.loads(line) for line in (root / "output.jsonl").read_text().splitlines() if line]
if not any(item.get("type") == "response" and item.get("command") == "prompt" and item.get("success") for item in output):
    raise SystemExit(f"RPC prompt acknowledgement missing: {output!r}")

sessions = list((root / "sessions").rglob("*.jsonl"))
if len(sessions) != 1:
    raise SystemExit(f"expected one persisted session, got {sessions!r}")
entries = [json.loads(line) for line in sessions[0].read_text().splitlines() if line]
users = [entry["message"] for entry in entries if entry.get("type") == "message" and entry.get("message", {}).get("role") == "user"]
content = users[-1].get("content")
if not isinstance(content, list) or not any(item.get("type") == "image" and item.get("mimeType") == "image/png" for item in content):
    raise SystemExit(f"RPC image did not survive session persistence: {users[-1]!r}")
PY

echo 'e2e: RPC image prompt reaches provider and persisted session OK'
