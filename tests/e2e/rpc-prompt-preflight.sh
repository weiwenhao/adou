#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-rpc-prompt-preflight-e2e.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

output=$(printf '%s\n' '{"id":"missing-key","type":"prompt","message":"hello"}' | \
    env -u DEEPSEEK_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
    PI_CODING_AGENT_DIR="$tmp_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --mode rpc --no-session --provider deepseek --model deepseek-v4-flash --thinking off)

python3 - "$output" <<'PY'
import json
import sys

items = [json.loads(line) for line in sys.argv[1].splitlines() if line.strip()]
responses = [item for item in items if item.get("id") == "missing-key"]
if len(responses) != 1:
    raise SystemExit(f"expected one prompt preflight response: {items!r}")
response = responses[0]
if response.get("type") != "response" or response.get("command") != "prompt" or response.get("success") is not False:
    raise SystemExit(f"missing-key prompt did not fail during preflight: {items!r}")
if "No API key" not in response.get("error", ""):
    raise SystemExit(f"missing-key prompt error did not identify authentication: {response!r}")
if any(item.get("type") in ("agent_start", "session_end") for item in items):
    raise SystemExit(f"prompt emitted an agent lifecycle after failed preflight: {items!r}")
if any(item.get("id") == "missing-key" and item.get("success") is True for item in items):
    raise SystemExit(f"prompt was acknowledged before authentication failure: {items!r}")
PY

plain_output="$tmp_dir/plain-output"
if ! env -u DEEPSEEK_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
    PI_CODING_AGENT_DIR="$tmp_dir/plain-agent" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/plain-sessions" \
    "$binary" --print --no-session --provider deepseek --model deepseek-v4-flash --thinking off hello > "$plain_output" 2>&1; then
    echo 'e2e: one-shot missing-key invocation returned a hard process failure' >&2
    cat "$plain_output" >&2
    exit 1
fi
if grep -q 'coroutine.*uncaught\|panic\|backtrace' "$plain_output"; then
    echo 'e2e: one-shot missing-key invocation exposed a Nature backtrace' >&2
    cat "$plain_output" >&2
    exit 1
fi
if ! grep -q 'No API key' "$plain_output"; then
    echo 'e2e: one-shot missing-key invocation did not report the preflight error' >&2
    cat "$plain_output" >&2
    exit 1
fi

echo 'e2e: prompt authentication preflight matches Pi response timing OK'
