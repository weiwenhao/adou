#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-auth-print.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
export HOME="$tmp_dir/home"
export PI_CODING_AGENT_DIR="$tmp_dir/agent"
mkdir -p "$HOME" "$PI_CODING_AGENT_DIR"

# shellcheck source=lib/deepseek-test-config.sh
. "$(dirname -- "$0")/lib/deepseek-test-config.sh"

# A failed credential print must keep stdout empty and write "Error: " to
# stderr with a non-zero exit so callers can tell a missing credential from
# a printed one.
run_failing() {
    if "$binary" "$@" >"$tmp_dir/out" 2>"$tmp_dir/err"; then
        echo "e2e: expected failure: $*" >&2
        exit 1
    fi
    [ ! -s "$tmp_dir/out" ] || {
        echo "e2e: failure leaked to stdout: $(cat "$tmp_dir/out")" >&2
        exit 1
    }
    rg -q '^Error: ' "$tmp_dir/err" || {
        echo "e2e: failure lacks Error: prefix on stderr: $(cat "$tmp_dir/err")" >&2
        exit 1
    }
}

# Provider-prefixed model prints the configured key alone on stdout, with
# an empty stderr.
out=$(DEEPSEEK_API_KEY="$DEEPSEEK_TEST_API_KEY" "$binary" auth print-api-key --model "$DEEPSEEK_TEST_MODEL_REF" 2>"$tmp_dir/err")
[ "$out" = "$DEEPSEEK_TEST_API_KEY" ] || { echo "e2e: unexpected stdout length ${#out}" >&2; exit 1; }
[ ! -s "$tmp_dir/err" ] || { echo "e2e: success leaked to stderr: $(cat "$tmp_dir/err")" >&2; exit 1; }

# Explicit provider works for bare model ids.
out=$(DEEPSEEK_API_KEY="$DEEPSEEK_TEST_API_KEY" "$binary" auth print-api-key --model "$DEEPSEEK_TEST_MODEL" --provider deepseek)
[ "$out" = "$DEEPSEEK_TEST_API_KEY" ] || { echo "e2e: unexpected stdout length ${#out}" >&2; exit 1; }

# Missing provider: stdout empty, Error: on stderr, non-zero exit.
run_failing auth print-api-key --model deepseek-v4-flash

# Unconfigured provider: same contract.
run_failing_with_env() {
    env DEEPSEEK_API_KEY= "$binary" "$@" >"$tmp_dir/out" 2>"$tmp_dir/err" && {
        echo "e2e: expected failure: $*" >&2
        exit 1
    }
    [ ! -s "$tmp_dir/out" ] || {
        echo "e2e: failure leaked to stdout: $(cat "$tmp_dir/out")" >&2
        exit 1
    }
    rg -q '^Error: ' "$tmp_dir/err" || {
        echo "e2e: failure lacks Error: prefix on stderr: $(cat "$tmp_dir/err")" >&2
        exit 1
    }
}
run_failing_with_env auth print-api-key --model deepseek/deepseek-v4-flash

# --api-key is rejected like Pi.
run_failing auth print-api-key --model deepseek-v4-flash --api-key x

# Unknown flag: args errors use the same contract.
run_failing auth print-api-key --model deepseek/deepseek-v4-flash --bogus

echo "e2e: auth print-api-key keeps stdout/stderr separated like Pi"
