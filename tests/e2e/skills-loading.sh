#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi
binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary")

port=${ADOU_E2E_SKILLS_PORT:-18981}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

project_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-skills-e2e.XXXXXX")
server_log=$(mktemp "${TMPDIR:-/tmp}/adou-skills-e2e-server.XXXXXX")
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$project_dir" "$server_log"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$project_dir/.pi/skills/demo"
cat > "$project_dir/.pi/skills/demo/SKILL.md" <<'MD'
---
name: demo
description: A demo skill injected into the system prompt
---
Instructions for the demo skill.
MD

python3 "$script_dir/skills-fixture-server.py" "$port" > "$server_log" 2>&1 &
server_pid=$!

sleep 1
if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "e2e: skills fixture server failed to start" >&2
    cat "$server_log" >&2
    exit 1
fi

output=$(cd "$project_dir" && PI_CODING_AGENT_DIR="$project_dir/agent" \
    DEEPSEEK_API_KEY=skills-e2e-key \
    "$binary" --provider deepseek --model deepseek/deepseek-v4-flash \
    --base-url "http://127.0.0.1:$port" --max-tokens 128 --no-session -p "hi" 2>&1)

case "$output" in
    *'ok'*) ;;
    *)
        echo "e2e: skills prompt did not return the fixture reply" >&2
        echo "output: $output" >&2
        exit 1
        ;;
esac

body=$(cat "$server_log")
python3 - "$server_log" <<'PY'
import json
import sys

path = sys.argv[1]
body = open(path).read().strip()
if not body.startswith("{"):
    raise SystemExit(f"e2e: no request body captured: {body!r}")
payload = json.loads(body)
messages = payload.get("messages", [])
system_text = ""
for message in messages:
    if message.get("role") == "system":
        system_text += message.get("content", "")
if "<available_skills>" not in system_text:
    raise SystemExit("e2e: system prompt does not include available_skills")
if "<name>demo</name>" not in system_text:
    raise SystemExit("e2e: system prompt does not include the demo skill")
if "A demo skill injected into the system prompt" not in system_text:
    raise SystemExit("e2e: system prompt does not include the skill description")
PY
echo 'e2e: skills loading and system prompt injection OK'
