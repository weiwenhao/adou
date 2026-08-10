#!/bin/sh
set -eu

# Extension runtime is disabled: even with an executable JS fixture in the
# user extensions directory, startup must not load it, get_commands must not
# surface extension commands, and the run_command protocol entry is removed.
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-extension-disabled-e2e.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

agent_dir="$tmp_dir/agent"
mkdir -p "$agent_dir/extensions"
cp "$(dirname -- "$0")/../fixtures/hello_extension.js" "$agent_dir/extensions/hello.js"

printf '%s\n' \
    '{"id":"commands","type":"get_commands"}' \
    '{"id":"run","type":"run_command","name":"hello","args":""}' \
    | PI_CODING_AGENT_DIR="$agent_dir" \
      PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions" \
      "$binary" --mode rpc --offline --no-session --no-context-files --debug \
        2>"$tmp_dir/stderr" >"$tmp_dir/stdout"

# 1. The extension fixture must not be loaded: no load log, no QuickJS runtime.
if grep -q '\[adou debug\] extension' "$tmp_dir/stderr"; then
    echo "e2e: extension activity in debug output despite being disabled" >&2
    cat "$tmp_dir/stderr" >&2
    exit 1
fi

# 2. get_commands keeps prompt templates and skills but no extension commands.
if ! grep -q '"command":"get_commands"' "$tmp_dir/stdout"; then
    echo "e2e: get_commands response missing" >&2
    cat "$tmp_dir/stdout" >&2
    exit 1
fi
if grep -q '"name":"hello"' "$tmp_dir/stdout" || grep -q 'extension:' "$tmp_dir/stdout"; then
    echo "e2e: extension command surfaced in get_commands despite being disabled" >&2
    cat "$tmp_dir/stdout" >&2
    exit 1
fi

# 3. run_command is removed from the protocol: explicit unknown-command error.
if ! grep -q '"command":"run_command"' "$tmp_dir/stdout" || ! grep -q '"success":false' "$tmp_dir/stdout" || ! grep -q 'Unknown command: run_command' "$tmp_dir/stdout"; then
    echo "e2e: run_command did not return an unknown-command error" >&2
    cat "$tmp_dir/stdout" >&2
    exit 1
fi

echo "e2e: extension runtime is disabled and fixtures stay inert"
