#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-cli-boundaries.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

# 1. No TTY and no prompt: the interactive-mode diagnostic.
out=$("$binary" --offline --no-context-files --no-session </dev/null 2>&1)
if ! printf '%s' "$out" | rg -q 'requires a TTY'; then
    echo "e2e: missing TTY diagnostic differs" >&2
    echo "$out" >&2
    exit 1
fi

# 2. Empty piped stdin with --print: no crash, no provider call.
out=$(echo -n "" | "$binary" --offline --no-context-files --no-session --print 2>&1 || true)
if printf '%s' "$out" | rg -q 'panic|uncaught|Error:'; then
    echo "e2e: empty stdin produced an unexpected diagnostic" >&2
    echo "$out" >&2
    exit 1
fi

# 3. Corrupt session file: friendly error with a non-zero exit.
printf 'garbage\nnot-jsonl\n' > "$tmp_dir/corrupt.jsonl"
if DEEPSEEK_API_KEY=sk-test "$binary" --no-context-files --print --session "$tmp_dir/corrupt.jsonl" 'hi' >"$tmp_dir/out" 2>&1; then
    echo "e2e: corrupt session must fail" >&2
    exit 1
fi
if ! rg -q 'Error: session file has no valid header' "$tmp_dir/out"; then
    echo "e2e: corrupt session error message differs" >&2
    cat "$tmp_dir/out" >&2
    exit 1
fi

# 4. Missing session file: offline mode rejects the prompt instead of
# hanging on a network call.
out=$(DEEPSEEK_API_KEY=sk-test "$binary" --offline --no-context-files --print --session "$tmp_dir/missing.jsonl" 'hi' 2>&1)
if printf '%s' "$out" | rg -q 'panic|uncaught'; then
    echo "e2e: missing session produced a crash" >&2
    echo "$out" >&2
    exit 1
fi

echo "e2e: startup boundary diagnostics (no TTY, empty stdin, corrupt/missing session) are explicit"
