#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-rpc-shape.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
output="$tmp_dir/output.jsonl"

printf '%s\n' \
    '' \
    '{' \
    '{"type":"get_state"}' \
    '{"type":"get_session_stats"}' \
    '{"type":"get_last_assistant_text"}' \
    '{"id":"bash","type":"bash","command":"printf shape"}' \
  | PI_CODING_AGENT_DIR="$tmp_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --mode rpc --no-session --no-context-files \
      --provider deepseek --model deepseek-v4-flash --thinking off --api-key rpc-shape-key \
      > "$output"

python3 - "$output" <<'PY'
import json
import sys

items = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
responses = {item.get("command"): item for item in items if item.get("type") == "response"}

parse_errors = [item for item in items if item.get("type") == "response" and item.get("command") == "parse"]
if len(parse_errors) != 2 or any(item.get("success") is not False for item in parse_errors):
    raise SystemExit(f"blank and malformed JSONL lines must produce parse errors: {items!r}")
if not all(item.get("error", "").startswith("Failed to parse command:") for item in parse_errors):
    raise SystemExit(f"parse errors must use Pi's diagnostic prefix: {parse_errors!r}")

for command in ("get_state", "get_session_stats", "get_last_assistant_text", "bash"):
    if command not in responses or responses[command].get("success") is not True:
        raise SystemExit(f"RPC {command} response missing or failed: {items!r}")

for command in ("get_state", "get_session_stats", "get_last_assistant_text"):
    if "id" in responses[command]:
        raise SystemExit(f"Pi omits an absent command id, but {command} returned one: {responses[command]!r}")

state = responses["get_state"].get("data", {})
if "sessionFile" in state or "sessionName" in state:
    raise SystemExit(f"undefined Pi state fields must be omitted: {state!r}")

stats = responses["get_session_stats"].get("data", {})
if "sessionFile" in stats:
    raise SystemExit(f"undefined Pi stats sessionFile must be omitted: {stats!r}")

last_text = responses["get_last_assistant_text"].get("data", {}).get("text", "missing")
if last_text is not None:
    raise SystemExit(f"missing assistant text must be null: {responses['get_last_assistant_text']!r}")

bash = responses["bash"].get("data", {})
if bash.get("output") != "shape" or bash.get("exitCode") != 0:
    raise SystemExit(f"successful Bash result shape mismatch: {bash!r}")
if "fullOutputPath" in bash:
    raise SystemExit(f"optional fullOutputPath should be omitted: {bash!r}")

print("e2e: RPC optional fields and Bash result shape match Pi JSON serialization OK")
PY
