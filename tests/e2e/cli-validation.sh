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
if ADOU_CODING_AGENT_DIR="$tmp_dir/agent-name" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-name" \
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
if ADOU_CODING_AGENT_DIR="$tmp_dir/agent-key" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-key" \
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

if ! ADOU_CODING_AGENT_DIR="$tmp_dir/agent-ephemeral" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-ephemeral" \
    "$binary" --no-session --session-id ephemeral-id --offline > /dev/null 2>&1; then
    echo 'e2e: Pi-compatible --no-session --session-id combination was rejected' >&2
    exit 1
fi

fork_source="$tmp_dir/fork-source.jsonl"
printf '%s\n' '{"type":"session","version":3,"id":"fork-source","timestamp":"2026-01-01T00:00:00.000Z","cwd":"'"$tmp_dir"'"}' > "$fork_source"
if ! ADOU_CODING_AGENT_DIR="$tmp_dir/agent-fork" \
    ADOU_SESSION_DIR="$tmp_dir/sessions-fork" \
    "$binary" --fork "$fork_source" --session-id child-id --offline --no-context-files > /dev/null 2>&1; then
    echo 'e2e: Pi-compatible --fork --session-id combination was rejected' >&2
    exit 1
fi

invalid_id_output="$tmp_dir/invalid-id"
if "$binary" --session-id '.bad' --offline > "$invalid_id_output" 2>&1; then
    echo 'e2e: invalid session id was accepted' >&2
    cat "$invalid_id_output" >&2
    exit 1
fi
if ! rg -F -- 'Session id must be non-empty' "$invalid_id_output" >/dev/null; then
    echo 'e2e: invalid session-id diagnostic differs from Pi' >&2
    cat "$invalid_id_output" >&2
    exit 1
fi

conflict_output="$tmp_dir/session-id-conflict"
if "$binary" --session-id child-id --continue --offline > "$conflict_output" 2>&1; then
    echo 'e2e: --session-id --continue combination was accepted' >&2
    cat "$conflict_output" >&2
    exit 1
fi
if ! rg -F -- '--session-id cannot be combined with --continue' "$conflict_output" >/dev/null; then
    echo 'e2e: session-id conflict diagnostic differs from Pi' >&2
    cat "$conflict_output" >&2
    exit 1
fi

echo 'e2e: Pi startup argument validation OK'
