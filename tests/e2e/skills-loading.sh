#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi
binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary")

# A free random port so stale servers from failed runs cannot hijack this
# script's fixture; ADOU_E2E_SKILLS_PORT keeps an explicit override for
# debugging.
port=${ADOU_E2E_SKILLS_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

project_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-skills-e2e.XXXXXX")
home_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-skills-home.XXXXXX")
server_log=$(mktemp "${TMPDIR:-/tmp}/adou-skills-e2e-server.XXXXXX")
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$project_dir" "$home_dir" "$server_log"
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

# Run one headless invocation against the fixture and check the n-th captured
# request body (the server appends one JSON body line per request).  HOME,
# the agent dir and the session dir are isolated so a real ~/.agents/skills
# or trust store can never leak into the trust branches.
run_case() {
    name=$1
    expected_index=$2
    shift 2
    output=$(cd "$project_dir" && HOME="$home_dir" \
        ADOU_CODING_AGENT_DIR="$home_dir/.pi/agent" \
        DEEPSEEK_API_KEY=skills-e2e-key \
        "$binary" --provider deepseek --model deepseek/deepseek-v4-flash \
        --base-url "http://127.0.0.1:$port" --max-tokens 128 --no-session -p "hi" "$@" 2>&1)
    case "$output" in
        *'ok'*)
            ;;
        *)
            echo "e2e: $name did not return the fixture reply" >&2
            echo "output: $output" >&2
            exit 1
            ;;
    esac
    body=$(sed -n "${expected_index}p" "$server_log")
    if [ -z "$body" ]; then
        echo "e2e: $name captured no request body" >&2
        exit 1
    fi
    python3 -c '
import json
import sys
body = sys.argv[1]
assert body.startswith("{" ), f"no request body captured: {body!r}"
payload = json.loads(body)
system_text = ""
for message in payload.get("messages", []):
    if message.get("role") == "system":
        system_text += message.get("content", "")
sys.stdout.write(system_text)
' "$body" > "${server_log}.body"
    echo "e2e: $name fixture round-trip OK"
}

# 1. Trusted project: the .pi/skills/demo skill is injected.  The fixture
# hosts trust-requiring resources with no saved decision, so an explicit
# --approve mirrors Pi's startup selector outcome (headless 'ask' resolves
# untrusted).
run_case "trusted default discovery" 1 --approve
if ! rg -q '<available_skills>' "${server_log}.body" || ! rg -q '<name>demo</name>' "${server_log}.body"; then
    echo "e2e: trusted default discovery did not inject the demo skill" >&2
    exit 1
fi
if ! rg -q 'A demo skill injected into the system prompt' "${server_log}.body"; then
    echo "e2e: trusted default discovery lost the skill description" >&2
    exit 1
fi

# 2. Without the read tool the skills block must not appear in the prompt.
run_case "no-tools gating" 2 --no-tools
if rg -q '<available_skills>' "${server_log}.body"; then
    echo "e2e: --no-tools still injected available_skills" >&2
    exit 1
fi

# 3. --no-skills disables default discovery.
run_case "no-skills gating" 3 --no-skills
if rg -q '<available_skills>' "${server_log}.body"; then
    echo "e2e: --no-skills still injected available_skills" >&2
    exit 1
fi

# 4. Explicit --skill paths pierce --no-skills.
run_case "explicit path with no-skills" 4 --no-skills --skill "$project_dir/.pi/skills/demo"
if ! rg -q '<available_skills>' "${server_log}.body" || ! rg -q '<name>demo</name>' "${server_log}.body"; then
    echo "e2e: explicit --skill with --no-skills did not inject the skill" >&2
    exit 1
fi

# 5. Untrusted projects skip project-scope discovery.
run_case "untrusted project" 5 --no-approve
if rg -q '<available_skills>' "${server_log}.body"; then
    echo "e2e: untrusted project still injected available_skills" >&2
    exit 1
fi

echo 'e2e: skills loading, gating and trust branches OK'
