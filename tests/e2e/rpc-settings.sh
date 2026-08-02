#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-rpc-settings.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
agent_dir="$tmp_dir/agent"
session_dir="$tmp_dir/sessions"
first_output="$tmp_dir/first.jsonl"
second_output="$tmp_dir/second.jsonl"

run_rpc() {
    output=$1
    shift
    PI_CODING_AGENT_DIR="$agent_dir" \
    PI_CODING_AGENT_SESSION_DIR="$session_dir" \
    "$binary" --mode rpc --no-session --no-context-files \
        --provider deepseek --model deepseek-v4-flash --api-key rpc-e2e-key \
        "$@" > "$output"
}

cat <<'EOF' | run_rpc "$first_output"
{"id":"state0","type":"get_state"}
{"id":"model","type":"set_model","provider":"deepseek","modelId":"deepseek-v4-flash"}
{"id":"compact","type":"set_auto_compaction","enabled":false}
{"id":"retry","type":"set_auto_retry","enabled":false}
{"id":"steer","type":"set_steering_mode","mode":"all"}
{"id":"follow","type":"set_follow_up_mode","mode":"all"}
{"id":"thinking","type":"get_available_thinking_levels"}
{"id":"state1","type":"get_state"}
{"id":"commands","type":"get_commands"}
{"id":"unknown","type":"not_a_pi_command"}
EOF

cat <<'EOF' | run_rpc "$second_output"
{"id":"state2","type":"get_state"}
EOF

python3 - "$first_output" "$second_output" "$agent_dir/settings.json" <<'PY'
import json
import sys

first_path, second_path, settings_path = sys.argv[1:]

def read(path):
    return [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]

first = read(first_path)
second = read(second_path)
by_id = {item.get("id"): item for item in first if "id" in item}

for key in ("model", "compact", "retry", "steer", "follow"):
    response = by_id.get(key)
    if not response or response.get("type") != "response" or response.get("success") is not True:
        raise SystemExit(f"rpc setting command failed: {key}: {response!r}")

state1 = by_id.get("state1", {}).get("data", {})
if state1.get("autoCompactionEnabled") is not False:
    raise SystemExit(f"RPC state did not update auto compaction: {state1!r}")
if state1.get("steeringMode") != "all" or state1.get("followUpMode") != "all":
    raise SystemExit(f"RPC state did not update queue modes: {state1!r}")

levels = by_id.get("thinking", {}).get("data", {}).get("levels")
if levels != ["off", "high", "max"]:
    raise SystemExit(f"DeepSeek supported thinking levels differ from Pi: {levels!r}")

commands = by_id.get("commands", {}).get("data", {}).get("commands", [])
names = {item.get("name") for item in commands}
if not {"model", "login", "compact", "quit"}.issubset(names):
    raise SystemExit(f"RPC command registry is incomplete: {names!r}")

unknown = by_id.get("unknown")
if not unknown or unknown.get("success") is not False or "Unknown command" not in unknown.get("error", ""):
    raise SystemExit(f"RPC unknown-command response differs from Pi: {unknown!r}")

state2 = next((item for item in second if item.get("id") == "state2"), {}).get("data", {})
if state2.get("autoCompactionEnabled") is not False or state2.get("steeringMode") != "all" or state2.get("followUpMode") != "all":
    raise SystemExit(f"RPC settings did not persist across restart: {state2!r}")

settings = json.load(open(settings_path, encoding="utf-8"))
if settings.get("retryEnabled") is not False:
    raise SystemExit(f"RPC retry setting was not persisted: {settings!r}")
if settings.get("defaultProvider") != "deepseek" or settings.get("defaultModel") != "deepseek-v4-flash":
    raise SystemExit(f"RPC setting update replaced unrelated model preferences: {settings!r}")
PY

echo 'e2e: RPC settings, thinking levels, command registry, and persistence OK'
