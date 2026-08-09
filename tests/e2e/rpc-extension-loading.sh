#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-rpc-extension-e2e.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

agent_dir="$tmp_dir/agent"
mkdir -p "$agent_dir/extensions"
cp "$(dirname -- "$0")/../fixtures/hello_extension.js" "$agent_dir/extensions/hello.js"

# Startup loads the user extension before the RPC loop starts; the debug log
# must record the load with its registration counts while RPC stdout stays
# clean JSONL.  --offline keeps the run free of provider calls.
printf '%s\n' \
    '{"id":"state","type":"get_state"}' \
    '{"id":"commands","type":"get_commands"}' \
    '{"id":"run","type":"run_command","name":"hello","args":""}' \
    '{"id":"missing","type":"run_command","name":"does-not-exist","args":""}' \
    | PI_CODING_AGENT_DIR="$agent_dir" \
      PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions" \
      "$binary" --mode rpc --offline --no-session --no-context-files --debug \
        2>"$tmp_dir/stderr" >"$tmp_dir/stdout"

loaded_line=$(grep '\[adou debug\] extension: loaded' "$tmp_dir/stderr" || true)
if [ -z "$loaded_line" ]; then
    echo "e2e: extension load not logged in debug output: $tmp_dir/stderr" >&2
    cat "$tmp_dir/stderr" >&2
    exit 1
fi
if ! printf '%s' "$loaded_line" | grep -q 'hello.js'; then
    echo "e2e: extension load log does not name hello.js: $loaded_line" >&2
    exit 1
fi
if ! printf '%s' "$loaded_line" | grep -q '(2 tools, 1 commands)'; then
    echo "e2e: extension registration counts missing from load log: $loaded_line" >&2
    exit 1
fi
if ! grep -q '\[adou debug\] startup:' "$tmp_dir/stderr"; then
    echo "e2e: startup debug log missing from stderr" >&2
    exit 1
fi
if grep -q '\[adou debug\]' "$tmp_dir/stdout"; then
    echo "e2e: debug output contaminated RPC stdout" >&2
    cat "$tmp_dir/stdout" >&2
    exit 1
fi

# get_commands surfaces the extension command with its source metadata.
if ! grep -q '"command":"get_commands"' "$tmp_dir/stdout" || ! grep -q '"name":"hello"' "$tmp_dir/stdout" || ! grep -q 'extension:user' "$tmp_dir/stdout"; then
    echo "e2e: extension command missing from get_commands response" >&2
    cat "$tmp_dir/stdout" >&2
    exit 1
fi

# run_command executes the registered JS handler and returns its result.
if ! grep -q '"command":"run_command"' "$tmp_dir/stdout" || ! grep -q 'Hello from the JS extension' "$tmp_dir/stdout"; then
    echo "e2e: run_command did not return the extension handler result" >&2
    cat "$tmp_dir/stdout" >&2
    exit 1
fi

# Unknown extension commands are explicit RPC errors, not silent successes.
if ! grep -q '"command":"run_command"' "$tmp_dir/stdout" || ! grep -q '"success":false' "$tmp_dir/stdout" || ! grep -q 'not found' "$tmp_dir/stdout"; then
    echo "e2e: unknown extension command did not produce an explicit RPC error" >&2
    cat "$tmp_dir/stdout" >&2
    exit 1
fi

echo "e2e: JS extension loads at startup and its registrations are visible"
