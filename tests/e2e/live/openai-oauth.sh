#!/bin/sh
set -eu

if [ "${ADOU_LIVE_OPENAI_OAUTH:-0}" != 1 ]; then
    echo 'e2e: live OpenAI OAuth skipped (set ADOU_LIVE_OPENAI_OAUTH=1)'
    exit 0
fi

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../../build/bin" && pwd)/adou}
agent_dir=${ADOU_CODING_AGENT_DIR:-${HOME}/.adou/agent}
auth_file=${agent_dir}/auth.json
if [ ! -x "$binary" ] || [ ! -f "$auth_file" ]; then
    echo 'e2e: live OpenAI OAuth requires the built Adou binary and an auth.json' >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo 'e2e: live OpenAI OAuth requires jq' >&2
    exit 2
fi

jq -e '.["openai-codex"] | .type == "oauth" and (.access | length > 0) and (.refresh | length > 0) and ((.accountId // .account_id) | length > 0)' "$auth_file" >/dev/null

reply=$(
    "$binary" --provider openai-codex --model gpt-5.4-mini --print \
        --no-session --no-context-files --thinking off --max-tokens 24 \
        'Reply with exactly: ADOU_LIVE_OK'
)
case "$reply" in
    *ADOU_LIVE_OK*) ;;
    *) echo 'e2e: live OpenAI OAuth request failed' >&2; exit 1 ;;
esac

scratch=$(mktemp -d "${TMPDIR:-/tmp}/adou-openai-refresh.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
cp "$auth_file" "$scratch/auth.json"
touch "$scratch/.adou-setup"
jq '.["openai-codex"].expires = 1' "$scratch/auth.json" > "$scratch/auth.next.json"
mv "$scratch/auth.next.json" "$scratch/auth.json"

refresh_reply=$(
    ADOU_CODING_AGENT_DIR="$scratch" "$binary" --provider openai-codex \
        --model gpt-5.4-mini --print --no-session --no-context-files \
        --no-tools --thinking off --max-tokens 24 \
        'Reply with exactly: ADOU_REFRESH_OK'
)
case "$refresh_reply" in
    *ADOU_REFRESH_OK*) ;;
    *) echo 'e2e: refreshed OpenAI OAuth request failed' >&2; exit 1 ;;
esac

now_ms=$(($(date +%s) * 1000))
expires=$(jq -r '.["openai-codex"].expires // 0' "$scratch/auth.json")
[ "$expires" -gt "$now_ms" ]
echo 'e2e: live OpenAI OAuth request and refresh recovery passed'
