#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

expected='anthropic/claude-sonnet-4-5'
actual=$($binary --list-models SONNET)
if [ "$actual" != "$expected" ]; then
    echo "e2e: partial model lookup mismatch" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
fi

expected='openai/gpt-5.1-codex'
actual=$($binary --list-models '*/gpt-*')
if [ "$actual" != "$expected" ]; then
    echo "e2e: glob model lookup mismatch" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
fi

echo 'e2e: model selection OK'

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-model-e2e.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
state=$(printf '%s\n' '{"id":"1","type":"get_state"}' | \
    PI_CODING_AGENT_DIR="$tmp_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --model sonnet --mode rpc --no-session)
case "$state" in
    *'"provider":"anthropic","id":"claude-sonnet-4-5"'*) ;;
    *)
        echo 'e2e: partial --model selector did not resolve to the canonical model' >&2
        echo "state: $state" >&2
        exit 1
        ;;
esac

echo 'e2e: canonical model resolution OK'
