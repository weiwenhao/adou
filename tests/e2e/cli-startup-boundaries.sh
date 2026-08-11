#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-cli-boundaries.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

# shellcheck source=lib/deepseek-test-config.sh
. "$(dirname -- "$0")/lib/deepseek-test-config.sh"

# Each stdin shape must return promptly: none of these may block on a
# read_piped_stdin() wait for EOF that the launcher never delivers.
# Offline mode keeps the assertions deterministic (no provider network).

# 1. /dev/null redirect.
out=$("$binary" --offline --no-context-files --no-session --print </dev/null 2>&1)
if printf '%s' "$out" | rg -q 'panic|uncaught'; then
    echo "e2e: /dev/null stdin produced a crash" >&2
    echo "$out" >&2
    exit 1
fi

# 2. Empty pipe (writer closed immediately).  printf is POSIX-portable here;
# `echo -n ""` emits a literal "-n" under /bin/sh, which would turn this
# case into a non-empty prompt and mask the hang it is guarding against.
out=$(printf '' | "$binary" --offline --no-context-files --no-session --print 2>&1 || true)
if printf '%s' "$out" | rg -q 'panic|uncaught'; then
    echo "e2e: empty piped stdin produced a crash" >&2
    echo "$out" >&2
    exit 1
fi

# 3. Pipe with content: the prompt must be rejected by offline mode rather
#    than sent to a provider.
out=$(printf 'hello' | "$binary" --offline --no-context-files --no-session --print 2>&1 || true)
printf '%s' "$out" | rg -q 'Offline mode cannot send prompts to a provider' || {
    echo "e2e: piped prompt did not hit the offline guard" >&2
    echo "$out" >&2
    exit 1
}

# 4. Regular file redirect with content.
printf 'hello' > "$tmp_dir/prompt.txt"
out=$("$binary" --offline --no-context-files --no-session --print <"$tmp_dir/prompt.txt" 2>&1 || true)
printf '%s' "$out" | rg -q 'Offline mode cannot send prompts to a provider' || {
    echo "e2e: file prompt did not hit the offline guard" >&2
    echo "$out" >&2
    exit 1
}

# 5. Corrupt session file: friendly error with a non-zero exit.
printf 'garbage\nnot-jsonl\n' > "$tmp_dir/corrupt.jsonl"
if DEEPSEEK_API_KEY="$DEEPSEEK_TEST_API_KEY" "$binary" --no-context-files --print --session "$tmp_dir/corrupt.jsonl" 'hi' >"$tmp_dir/out" 2>&1; then
    echo "e2e: corrupt session must fail" >&2
    exit 1
fi
if ! rg -q 'Error: session file has no valid header' "$tmp_dir/out"; then
    echo "e2e: corrupt session error message differs" >&2
    cat "$tmp_dir/out" >&2
    exit 1
fi

# 6. Missing session file with a positional prompt: offline mode rejects
#    the prompt instead of hanging on a network call.
out=$(DEEPSEEK_API_KEY="$DEEPSEEK_TEST_API_KEY" "$binary" --offline --no-context-files --print --session "$tmp_dir/missing.jsonl" 'hi' 2>&1)
printf '%s' "$out" | rg -q 'Offline mode cannot send prompts to a provider' || {
    echo "e2e: missing-session prompt did not hit the offline guard" >&2
    echo "$out" >&2
    exit 1
}

# 7. No TTY and no prompt: the interactive-mode diagnostic.
out=$("$binary" --offline --no-context-files --no-session </dev/null 2>&1)
if ! printf '%s' "$out" | rg -q 'requires a TTY'; then
    echo "e2e: missing TTY diagnostic differs" >&2
    echo "$out" >&2
    exit 1
fi

echo "e2e: startup boundaries (no TTY, /dev/null, empty/content pipes, regular file, corrupt/missing sessions) are explicit and prompt"
