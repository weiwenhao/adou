#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
[ -x "$binary" ] || { echo "e2e: Adou binary not found: $binary" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adou-server-cli.XXXXXX")
port=18952
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

export ADOU_CODING_AGENT_DIR="$tmp/agent"
export ADOU_SESSION_DIR="$tmp/sessions"
export DEEPSEEK_API_KEY=sk-server-cli-test
mkdir -p "$ADOU_CODING_AGENT_DIR" "$ADOU_SESSION_DIR" "$tmp/project"

"$binary" server --port "$port" serve >"$tmp/server.out" 2>"$tmp/server.err" &
server_pid=$!

python3 - "$port" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
deadline = time.time() + 10
while time.time() < deadline:
    try:
        socket.create_connection(("127.0.0.1", port), timeout=.2).close()
        break
    except OSError:
        time.sleep(.05)
else:
    raise SystemExit("server CLI did not listen")
PY

spawn=$("$binary" server --port "$port" spawn --cwd "$tmp/project" --label cli-test)
instance=$(printf '%s' "$spawn" | python3 -c 'import json,sys; print(json.load(sys.stdin)["instance"]["id"])')

python3 - "$binary" "$port" "$instance" <<'PY'
import json, subprocess, sys, time
binary, port, instance = sys.argv[1], sys.argv[2], sys.argv[3]
for _ in range(200):
    data = json.loads(subprocess.check_output([binary, "server", "--port", port, "status", instance]))
    if data["instance"]["status"] == "online":
        break
    time.sleep(.05)
else:
    raise SystemExit(f"instance did not become online: {data}")
listed = json.loads(subprocess.check_output([binary, "server", "--port", port, "list"]))
assert instance in [item["id"] for item in listed["instances"]]
rpc = json.loads(subprocess.check_output([binary, "server", "--port", port, "rpc", instance, '{"type":"get_state","id":"cli-rpc"}']))
assert rpc["response"]["id"] == "cli-rpc" and rpc["response"]["success"] is True
PY

stream_file="$tmp/rpc-stream.out"
(printf '%s\n' '{"type":"get_state","id":"cli-stream"}'; sleep 2) | "$binary" server --port "$port" rpc-stream "$instance" >"$stream_file"
stream=$(cat "$stream_file")
printf '%s' "$stream" | grep -q '"type":"rpc_ready"' || { echo "e2e: rpc-stream missing ready" >&2; cat "$stream_file" >&2; exit 1; }
printf '%s' "$stream" | grep -q '"id":"cli-stream"' || { echo "e2e: rpc-stream did not forward stdin command" >&2; cat "$stream_file" >&2; exit 1; }

stopped=$("$binary" server --port "$port" stop "$instance")
printf '%s' "$stopped" | grep -q '"type":"stop_result"' || { echo "e2e: stop command failed" >&2; exit 1; }
"$binary" server --help | grep -q 'rpc-stream' || { echo "e2e: server help missing rpc-stream" >&2; exit 1; }
[ "$("$binary" server --version)" = "0.1.0-dev" ] || { echo "e2e: server version differs" >&2; exit 1; }

echo "e2e: standalone server CLI list/spawn/status/rpc/rpc-stream/stop passed"
