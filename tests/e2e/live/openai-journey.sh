#!/bin/sh
set -eu

if [ "${ADOU_LIVE_OPENAI_JOURNEY:-0}" != 1 ]; then
    echo 'e2e: live OpenAI journey skipped (set ADOU_LIVE_OPENAI_JOURNEY=1)'
    exit 0
fi

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../../build/bin" && pwd)/adou}
agent_dir=${ADOU_CODING_AGENT_DIR:-${HOME}/.adou/agent}
auth_file=${agent_dir}/auth.json
if [ ! -x "$binary" ] || [ ! -f "$auth_file" ]; then
    echo 'e2e: live OpenAI journey requires the built Adou binary and an auth.json' >&2
    exit 2
fi

root=$(mktemp -d "${TMPDIR:-/tmp}/adou-openai-journey.XXXXXX")
trap 'rm -rf "$root"' EXIT INT TERM
mkdir -p "$root/agent" "$root/sessions"
cp "$auth_file" "$root/agent/auth.json"
touch "$root/agent/.adou-setup"

run_round() {
    marker=$1
    shift
    ADOU_CODING_AGENT_DIR="$root/agent" ADOU_SESSION_DIR="$root/sessions" \
        "$binary" --provider openai-codex --model gpt-5.4-mini --print \
        --no-context-files --no-tools --thinking off --max-tokens 24 \
        "$@" "Reply with exactly: $marker"
}

run_round ROUND_ONE_OK > "$root/one.out"
session_file=$(find "$root/sessions" -name '*.jsonl' -type f | head -n 1)
[ -n "$session_file" ]
run_round ROUND_TWO_OK --session "$session_file" > "$root/two.out"
run_round ROUND_THREE_OK --session "$session_file" > "$root/three.out"

grep -q ROUND_ONE_OK "$root/one.out"
grep -q ROUND_TWO_OK "$root/two.out"
grep -q ROUND_THREE_OK "$root/three.out"
jq -s -e '[.[] | select(.type=="message") | .message | select(.role=="user")] | length == 3' "$session_file" >/dev/null
jq -s -e '[.[] | select(.type=="message") | .message | select(.role=="assistant" and .stopReason=="stop")] | length == 3' "$session_file" >/dev/null
echo 'e2e: live OpenAI three-round persisted journey passed'
