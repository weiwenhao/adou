#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-auth-print.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

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
out=$(DEEPSEEK_API_KEY=sk-print-test "$binary" auth print-api-key --model deepseek/deepseek-v4-flash 2>"$tmp_dir/err")
[ "$out" = "sk-print-test" ] || { echo "e2e: unexpected stdout: $out" >&2; exit 1; }
[ ! -s "$tmp_dir/err" ] || { echo "e2e: success leaked to stderr: $(cat "$tmp_dir/err")" >&2; exit 1; }

# Explicit provider works for bare model ids.
out=$(DEEPSEEK_API_KEY=sk-print-test "$binary" auth print-api-key --model deepseek-v4-flash --provider deepseek)
[ "$out" = "sk-print-test" ] || { echo "e2e: unexpected stdout: $out" >&2; exit 1; }

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
