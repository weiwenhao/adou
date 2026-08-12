#!/bin/sh
set -eu

# CLI help/argument matrix e2e: the help text must list every parseable
# option, --help must exit 0 with no diagnostics on stdout, and the
# documented argument families must behave (validated by cli-validation.sh
# for error semantics; this script pins the help surface itself).
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

out=$("$binary" --help)
printf '%s' "$out" | rg -q '^adou - Nature coding agent with Pi core tools' || {
    echo "e2e: help lacks the banner line" >&2
    exit 1
}
printf '%s' "$out" | rg -q '^Usage:' || { echo "e2e: help lacks Usage" >&2; exit 1; }
printf '%s' "$out" | rg -q '^Options:' || { echo "e2e: help lacks Options" >&2; exit 1; }
printf '%s' "$out" | rg -q '^Environment:' || { echo "e2e: help lacks Environment" >&2; exit 1; }

# Every option the parser accepts must appear in the help text.  The
# argument matrix below mirrors the options implemented in src/config/args.n
# plus the startup/auth surfaces; extension/template/theme flags are
# intentionally excluded (resource toggles live in /config).
for option in \
    --provider --model --models --list-models --base-url --thinking --mode --serve-port \
    --session --session-id --session-dir --continue --resume --fork --name \
    --print --export --system-prompt --append-system-prompt \
    --no-context-files --no-tools --no-builtin-tools --tools --exclude-tools \
    --skill --no-skills \
    --no-session --approve --no-approve --offline --verbose --debug \
    --context-window --max-tokens --timeout-ms --max-retries \
    --reserve-tokens --keep-recent-tokens --no-compaction --api-key \
    --help --version; do
    printf '%s' "$out" | rg -q -- "$option" || {
        echo "e2e: help missing option --$option" >&2
        exit 1
    }
done

# Short aliases are documented too.
for alias in '-p' '-c' '-r' '-n' '-a' '-na' '-nc' '-nt' '-nbt' '-t' '-xt' '-ns' '-h' '-v'; do
    printf '%s' "$out" | rg -q -- "$alias" || {
        echo "e2e: help missing alias $alias" >&2
        exit 1
    }
done

# Help/version are pure stdout, no stderr diagnostics, exit 0.
err=$("$binary" --help 2>&1 >/dev/null)
[ -z "$err" ] || { echo "e2e: --help leaked to stderr: $err" >&2; exit 1; }
ver=$("$binary" --version)
printf '%s' "$ver" | rg -q 'adou ' || { echo "e2e: version line differs: $ver" >&2; exit 1; }

echo "e2e: help text covers the full argument matrix and stays quiet"
