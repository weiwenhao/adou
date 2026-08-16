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
third_output="$tmp_dir/third.jsonl"
fourth_output="$tmp_dir/fourth.jsonl"
fifth_output="$tmp_dir/fifth.jsonl"
legacy_session="$tmp_dir/legacy.jsonl"
project_session="$tmp_dir/project.jsonl"
project_dir="$tmp_dir/project"

run_rpc() {
    output=$1
    shift
    PI_CODING_AGENT_DIR="$agent_dir" \
    PI_CODING_AGENT_SESSION_DIR="$session_dir" \
    "$binary" --mode rpc --no-context-files \
        --provider deepseek --model deepseek-v4-flash --api-key rpc-e2e-key \
        --session-dir "$session_dir" --approve "$@" > "$output"
}

printf '%s\n' '{"id":"state0","type":"get_state"}' | run_rpc "$first_output"

parent=$(python3 - "$first_output" <<'PY'
import json
import os
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

python3 - "$legacy_session" "$PWD" "$project_session" "$project_dir" <<'PY'
import json
import os
import sys

path, cwd, project_path, project_cwd = sys.argv[1:]
header = {
    "type": "session",
    "version": 3,
    "id": "legacy-session",
    "timestamp": "2026-08-02T00:00:00.000Z",
    "cwd": cwd,
}
message = {
    "type": "message",
    "id": "legacy-message",
    "parentId": None,
    "timestamp": "2026-08-02T00:00:01.000Z",
    "message": {"role": "user", "content": "legacy prompt", "timestamp": 1},
}
with open(path, "w", encoding="utf-8") as stream:
    stream.write(json.dumps(header) + "\n")
    stream.write(json.dumps(message) + "\n")

os.makedirs(os.path.join(project_cwd, ".pi"), exist_ok=True)
os.makedirs(os.path.join(project_cwd, ".pi", "prompts"), exist_ok=True)
with open(os.path.join(project_cwd, ".pi", "prompts", "project-only.md"), "w", encoding="utf-8") as stream:
    stream.write("---\ndescription: Project-only prompt\n---\n\nPROJECT $@")
with open(os.path.join(project_cwd, ".pi", "settings.json"), "w", encoding="utf-8") as stream:
    json.dump(
        {
            "autoCompaction": False,
            "steeringMode": "all",
            "followUpMode": "all",
            "retryEnabled": False,
            "retryMaxAttempts": 2,
            "retryBaseDelayMs": 17,
        },
        stream,
    )
project_header = {
    "type": "session",
    "version": 3,
    "id": "project-session",
    "timestamp": "2026-08-02T00:00:00.000Z",
    "cwd": project_cwd,
}
project_model = {
    "type": "model_change",
    "id": "project-model",
    "parentId": None,
    "timestamp": "2026-08-02T00:00:01.000Z",
    "provider": "deepseek",
    "modelId": "deepseek-v4-flash",
}
project_thinking = {
    "type": "thinking_level_change",
    "id": "project-thinking",
    "parentId": "project-model",
    "timestamp": "2026-08-02T00:00:02.000Z",
    "thinkingLevel": "off",
}
with open(project_path, "w", encoding="utf-8") as stream:
    for entry in (project_header, project_model, project_thinking):
        stream.write(json.dumps(entry) + "\n")
PY

python3 - "$legacy_session" <<'PY' | run_rpc "$third_output" --session "$parent"
import json
import sys

print(json.dumps({"id": "switch", "type": "switch_session", "sessionPath": sys.argv[1]}))
print(json.dumps({"id": "state2", "type": "get_state"}))
PY

python3 - "$project_session" <<'PY' | run_rpc "$fourth_output" --session "$parent"
import json
import sys

print(json.dumps({"id": "commands-before-project", "type": "get_commands"}))
print(json.dumps({"id": "switch-project", "type": "switch_session", "sessionPath": sys.argv[1]}))
print(json.dumps({"id": "commands-project", "type": "get_commands"}))
print(json.dumps({"id": "state3", "type": "get_state"}))
PY

printf '%s\n' '{"id":"state4","type":"get_state"}' | run_rpc "$fifth_output" --session "$project_session"

python3 - "$first_output" "$second_output" "$third_output" "$fourth_output" "$fifth_output" "$parent" "$legacy_session" "$project_session" <<'PY'
import json
import os
import sys

first_path, second_path, third_path, fourth_path, fifth_path, parent, legacy_path, project_path = sys.argv[1:]

def read(path):
    return [json.loads(line) for line in open(path, encoding='utf-8') if line.strip()]

first = read(first_path)
second = read(second_path)
third = read(third_path)
fourth = read(fourth_path)
fifth = read(fifth_path)
state0 = next(item for item in first if item.get('id') == 'state0')
new = next(item for item in second if item.get('id') == 'new')
state1 = next(item for item in second if item.get('id') == 'state1')
switch = next(item for item in third if item.get('id') == 'switch')
state2 = next(item for item in third if item.get('id') == 'state2')
commands_before_project = next(item for item in fourth if item.get('id') == 'commands-before-project')
switch_project = next(item for item in fourth if item.get('id') == 'switch-project')
commands_project = next(item for item in fourth if item.get('id') == 'commands-project')
state3 = next(item for item in fourth if item.get('id') == 'state3')
state4 = next(item for item in fifth if item.get('id') == 'state4')

if new.get('type') != 'response' or new.get('success') is not True:
    raise SystemExit(f'RPC new_session failed: {new!r}')

old_state = state0.get('data', {})
new_state = state1.get('data', {})
with open(parent, encoding='utf-8') as stream:
    parent_header = json.loads(stream.readline())
    parent_entries = [json.loads(line) for line in stream if line.strip()]
if [entry.get('type') for entry in parent_entries[:2]] != ['model_change', 'thinking_level_change']:
    raise SystemExit(f'initial session did not persist model/thinking metadata: {parent_entries!r}')
new_file = new_state.get('sessionFile')
if not new_file or new_file == parent:
    raise SystemExit(f'new_session did not create a new persisted file: {new_state!r}')
if new_state.get('sessionId') == old_state.get('sessionId'):
    raise SystemExit(f'new_session reused the previous session id: {new_state!r}')

if switch.get('type') != 'response' or switch.get('success') is not True:
    raise SystemExit(f'RPC switch_session failed: {switch!r}')
if os.path.realpath(state2.get('data', {}).get('sessionFile', '')) != os.path.realpath(legacy_path):
    raise SystemExit(f'RPC switch_session did not bind the target session: {state2!r}')

with open(legacy_path, encoding='utf-8') as stream:
    legacy_header = json.loads(stream.readline())
    legacy_entries = [json.loads(line) for line in stream if line.strip()]
if [entry.get('type') for entry in legacy_entries] != ['message', 'thinking_level_change']:
    raise SystemExit(f'switch_session did not repair legacy thinking metadata: {legacy_entries!r}')

if switch_project.get('type') != 'response' or switch_project.get('success') is not True:
    raise SystemExit(f'RPC project switch failed: {switch_project!r}')
before_project_names = [item.get('name') for item in commands_before_project.get('data', {}).get('commands', [])]
if 'project-only' in before_project_names:
    raise SystemExit(f'project resource leaked before RPC session switch: {commands_before_project!r}')
if os.path.realpath(state3.get('data', {}).get('sessionFile', '')) != os.path.realpath(project_path):
    raise SystemExit(f'RPC project switch did not bind the target session: {state3!r}')
project_command_names = [item.get('name') for item in commands_project.get('data', {}).get('commands', [])]
if 'project-only' not in project_command_names:
    raise SystemExit(f'RPC project switch did not publish the target resource snapshot: {commands_project!r}')
project_state = state3.get('data', {})
if project_state.get('autoCompactionEnabled') is not False or project_state.get('steeringMode') != 'all' or project_state.get('followUpMode') != 'all':
    raise SystemExit(f'project .pi settings were not reloaded during session switch: {project_state!r}')

startup_project_state = state4.get('data', {})
if startup_project_state.get('autoCompactionEnabled') is not False or startup_project_state.get('steeringMode') != 'all' or startup_project_state.get('followUpMode') != 'all':
    raise SystemExit(f'project .pi settings were not loaded from a selected session cwd at startup: {startup_project_state!r}')

with open(new_file, encoding='utf-8') as stream:
    header = json.loads(stream.readline())
    entries = [json.loads(line) for line in stream if line.strip()]
if header.get('type') != 'session' or header.get('parentSession') != parent:
    raise SystemExit(f'new session header lost parentSession: {header!r}')
if header.get('id') != new_state.get('sessionId'):
    raise SystemExit(f'new session state/header ids differ: {new_state!r} vs {header!r}')
if [entry.get('type') for entry in entries[:2]] != ['model_change', 'thinking_level_change']:
    raise SystemExit(f'new session did not persist initial model/thinking metadata: {entries!r}')
PY

echo 'e2e: RPC new_session preserves parentSession and rebinds session state OK'
