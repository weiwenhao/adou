#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi
case "$binary" in
    /*) ;;
    *) binary="$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary")" ;;
esac

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-project-config-e2e.XXXXXX")
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

agent_dir="$tmp_dir/agent"
project_dir="$tmp_dir/project"
request_file="$tmp_dir/request.json"
port_file="$tmp_dir/port"

mkdir -p "$project_dir/.adou"
mkdir -p "$agent_dir"
printf '%s' '{"defaultProvider":"openai","defaultModel":"gpt-5.1-codex","defaultThinkingLevel":"high"}' > "$agent_dir/settings.json"
printf '%s' 'GLOBAL_SYSTEM' > "$agent_dir/SYSTEM.md"
printf '%s' 'PROJECT_SYSTEM' > "$project_dir/.adou/SYSTEM.md"
printf '%s' 'PROJECT_APPEND' > "$project_dir/.adou/APPEND_SYSTEM.md"
printf '%s' '{"defaultProvider":"anthropic","defaultModel":"claude-sonnet-4-5","defaultThinkingLevel":"off","enabledModels":["openai/gpt-5.1-codex:high","deepseek/deepseek-v4-flash:low"]}' > "$project_dir/.adou/settings.json"

python3 - "$port_file" "$request_file" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_path, request_path = sys.argv[1:3]

def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        with open(request_path, "wb") as output:
            output.write(body)
        stream = b"".join([
            event({"id": "project-config", "choices": [{"delta": {
                "role": "assistant", "content": "project-config-ok"
            }, "finish_reason": None}]}),
            event({"id": "project-config", "choices": [{"delta": {}, "finish_reason": "stop"}]}),
            event({"id": "project-config", "choices": [], "usage": {
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
with open(port_path, "w", encoding="ascii") as output:
    output.write(str(server.server_port))
server.handle_request()
PY
server_pid=$!

for _ in $(seq 1 100); do
    if [ -s "$port_file" ]; then break; fi
    sleep 0.01
done
if [ ! -s "$port_file" ]; then
    echo 'e2e: local project-config server did not start' >&2
    exit 1
fi
port=$(cat "$port_file")

state=$(printf '%s\n' '{"id":"state","type":"get_state"}' | (cd "$project_dir" && \
    ADOU_CODING_AGENT_DIR="$agent_dir" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-state" \
    "$binary" --mode rpc --no-session --approve))
python3 - "$state" <<'PY'
import json
import sys

items = [json.loads(line) for line in sys.argv[1].splitlines() if line.strip()]
state = next(item for item in items if item.get("id") == "state")
data = state.get("data", {})
model = data.get("model", {})
if (model.get("provider"), model.get("id")) != ("openai", "gpt-5.1-codex"):
    raise SystemExit(f"project enabledModels did not override global default model: {data!r}")
if data.get("thinkingLevel") != "high":
    raise SystemExit(f"project enabledModels did not apply its thinking suffix: {data!r}")
PY

# The scope check above intentionally proves the Pi initial-selection rule.
# Switch back to the project default before the provider request so this test
# can continue to exercise the DeepSeek OpenAI-compatible transport and the
# project SYSTEM.md precedence in the same invocation.
printf '%s' '{"defaultProvider":"deepseek","defaultModel":"deepseek-v4-flash","defaultThinkingLevel":"off"}' > "$project_dir/.adou/settings.json"

output_file="$tmp_dir/output"
if ! (cd "$project_dir" && \
    DEEPSEEK_API_KEY=e2e-project-key \
    ADOU_CODING_AGENT_DIR="$agent_dir" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-prompt" \
    "$binary" --base-url "http://127.0.0.1:$port/v1" --print --no-session --approve project-prompt > "$output_file" 2>&1); then
    echo 'e2e: project .adou prompt invocation failed' >&2
    cat "$output_file" >&2
    exit 1
fi
if [ "$(cat "$output_file")" != 'project-config-ok' ]; then
    echo 'e2e: project .adou prompt did not complete with the expected response' >&2
    cat "$output_file" >&2
    exit 1
fi

wait "$server_pid"
server_pid=''

python3 - "$request_file" <<'PY'
import json
import sys

body = json.load(open(sys.argv[1], encoding="utf-8"))
messages = body.get("messages", [])
system = next((item.get("content", "") for item in messages if item.get("role") == "system"), "")
if "PROJECT_SYSTEM" not in system:
    raise SystemExit(f"project SYSTEM.md was not selected over global SYSTEM.md: {system!r}")
if "PROJECT_APPEND" not in system:
    raise SystemExit(f"project APPEND_SYSTEM.md was not appended: {system!r}")
if "GLOBAL_SYSTEM" in system:
    raise SystemExit(f"global SYSTEM.md leaked through project override: {system!r}")
if body.get("model") != "deepseek-v4-flash":
    raise SystemExit(f"project model was not used for the provider request: {body!r}")
PY

echo 'e2e: project .adou settings and system prompt precedence OK'
