#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

port=${ADOU_E2E_RADIUS_PORT:-18980}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

server_log=$(mktemp "${TMPDIR:-/tmp}/adou-radius-e2e-server.XXXXXX")
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
    fi
    rm -f "$server_log"
}
trap cleanup EXIT HUP INT TERM

python3 "$script_dir/radius-pi-messages-server.py" "$port" > "$server_log" 2>&1 &
server_pid=$!

sleep 1
if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "e2e: radius pi-messages fixture server failed to start" >&2
    cat "$server_log" >&2
    exit 1
fi

# The local fixture asserts the request shape and answers with a complete
# pi-messages event stream; the CLI resolves radius/default through the
# registry and --base-url redirects it at the fixture.
output=$(PI_CODING_AGENT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/adou-radius-e2e.XXXXXX")" \
    RADIUS_API_KEY=radius-e2e-key \
    "$binary" --provider radius --model radius/default \
    --base-url "http://127.0.0.1:$port" --max-tokens 128 -p "hello" 2>&1)

case "$output" in
    *'你好，这是 radius 的回复。'*) ;;
    *)
        echo "e2e: radius pi-messages prompt did not return the fixture reply" >&2
        echo "output: $output" >&2
        cat "$server_log" >&2
        exit 1
        ;;
esac

if ! grep -q 'fixture: request shape ok' "$server_log"; then
    echo "e2e: radius fixture did not validate the request shape" >&2
    cat "$server_log" >&2
    exit 1
fi

echo 'e2e: radius pi-messages provider OK'
