#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-rpc-new-session.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
agent_dir="$tmp_dir/agent"
session_dir="$tmp_dir/sessions"
first_output="$tmp_dir/first.jsonl"
second_output="$tmp_dir/second.jsonl"

run_rpc() {
    output=$1
    shift
    PI_CODING_AGENT_DIR="$agent_dir" \
    PI_CODING_AGENT_SESSION_DIR="$session_dir" \
    "$binary" --mode rpc --no-context-files \
        --provider deepseek --model deepseek-v4-flash --api-key rpc-e2e-key \
        --session-dir "$session_dir" "$@" > "$output"
}

printf '%s\n' '{"id":"state0","type":"get_state"}' | run_rpc "$first_output"

parent=$(python3 - "$first_output" <<'PY'
import json
import sys

for line in open(sys.argv[1], encoding='utf-8'):
    if not line.strip():
        continue
    value = json.loads(line)
    if value.get('id') == 'state0':
        session_file = value.get('data', {}).get('sessionFile')
        if not session_file:
            raise SystemExit('initial RPC state did not expose a persisted session file')
        print(session_file)
        break
else:
    raise SystemExit('initial RPC state response missing')
PY
)

python3 - "$parent" <<'PY' | run_rpc "$second_output" --session "$parent"
import json
import sys

parent = sys.argv[1]
print(json.dumps({"id": "new", "type": "new_session", "parentSession": parent}))
print(json.dumps({"id": "state1", "type": "get_state"}))
PY

python3 - "$first_output" "$second_output" "$parent" <<'PY'
import json
import sys

first_path, second_path, parent = sys.argv[1:]

def read(path):
    return [json.loads(line) for line in open(path, encoding='utf-8') if line.strip()]

first = read(first_path)
second = read(second_path)
state0 = next(item for item in first if item.get('id') == 'state0')
new = next(item for item in second if item.get('id') == 'new')
state1 = next(item for item in second if item.get('id') == 'state1')

if new.get('type') != 'response' or new.get('success') is not True:
    raise SystemExit(f'RPC new_session failed: {new!r}')

old_state = state0.get('data', {})
new_state = state1.get('data', {})
new_file = new_state.get('sessionFile')
if not new_file or new_file == parent:
    raise SystemExit(f'new_session did not create a new persisted file: {new_state!r}')
if new_state.get('sessionId') == old_state.get('sessionId'):
    raise SystemExit(f'new_session reused the previous session id: {new_state!r}')

with open(new_file, encoding='utf-8') as stream:
    header = json.loads(stream.readline())
if header.get('type') != 'session' or header.get('parentSession') != parent:
    raise SystemExit(f'new session header lost parentSession: {header!r}')
if header.get('id') != new_state.get('sessionId'):
    raise SystemExit(f'new session state/header ids differ: {new_state!r} vs {header!r}')
PY

echo 'e2e: RPC new_session preserves parentSession and rebinds session state OK'
