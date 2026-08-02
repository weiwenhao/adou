#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-cli-validation-e2e.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

name_output="$tmp_dir/name"
if PI_CODING_AGENT_DIR="$tmp_dir/agent-name" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions-name" \
    "$binary" --name '   ' > "$name_output" 2>&1; then
    echo 'e2e: whitespace session name was accepted' >&2
    cat "$name_output" >&2
    exit 1
fi
if ! rg -F -- '--name requires a non-empty value' "$name_output" >/dev/null; then
    echo 'e2e: empty session-name diagnostic differs from Pi' >&2
    cat "$name_output" >&2
    exit 1
fi

key_output="$tmp_dir/key"
if PI_CODING_AGENT_DIR="$tmp_dir/agent-key" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions-key" \
    "$binary" --api-key cli-e2e-key > "$key_output" 2>&1; then
    echo 'e2e: api key without an explicit model was accepted' >&2
    cat "$key_output" >&2
    exit 1
fi
if ! rg -F -- '--api-key requires a model to be specified' "$key_output" >/dev/null; then
    echo 'e2e: api-key model requirement diagnostic differs from Pi' >&2
    cat "$key_output" >&2
    exit 1
fi

echo 'e2e: Pi startup argument validation OK'
