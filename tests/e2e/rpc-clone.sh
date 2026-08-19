#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

python3 - "$binary" <<'PY'
import json
import os
import select
import signal
import subprocess
import sys
import tempfile

binary = sys.argv[1]


def read_response(proc, request_id):
    deadline = __import__("time").monotonic() + 5
    while __import__("time").monotonic() < deadline:
        readable, _, _ = select.select([proc.stdout], [], [], 0.2)
        if not readable:
            continue
        line = proc.stdout.readline()
        if not line:
            break
        value = json.loads(line)
        if value.get("id") == request_id:
            return value
    raise SystemExit(f"did not receive RPC response for {request_id}")


with tempfile.TemporaryDirectory(prefix="adou-rpc-clone-") as root:
    cwd = os.getcwd()
    source = os.path.join(root, "source.jsonl")
    seed = [
        {
            "type": "session",
            "version": 3,
            "id": "rpc-clone-source",
            "timestamp": "2026-01-01T00:00:00.000Z",
            "cwd": cwd,
        },
        {
            "type": "model_change",
            "id": "m1",
            "parentId": None,
            "timestamp": "2026-01-01T00:00:01.000Z",
            "provider": "deepseek",
            "modelId": "deepseek-v4-flash",
        },
        {
            "type": "thinking_level_change",
            "id": "t1",
            "parentId": "m1",
            "timestamp": "2026-01-01T00:00:02.000Z",
            "thinkingLevel": "off",
        },
        {
            "type": "message",
            "id": "u1",
            "parentId": "t1",
            "timestamp": "2026-01-01T00:00:03.000Z",
            "message": {"role": "user", "content": "clone this session", "timestamp": 1},
        },
        {
            "type": "message",
            "id": "a1",
            "parentId": "u1",
            "timestamp": "2026-01-01T00:00:04.000Z",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": "source answer"}],
                "api": "openai-completions",
                "provider": "deepseek",
                "model": "deepseek-v4-flash",
                "stopReason": "stop",
                "timestamp": 2,
            },
        },
    ]
    with open(source, "w", encoding="utf-8") as output:
        for entry in seed:
            output.write(json.dumps(entry, separators=(",", ":")) + "\n")

    env = os.environ.copy()
    env.update(
        {
            "ADOU_CODING_AGENT_DIR": os.path.join(root, "agent"),
            "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
        }
    )
    proc = subprocess.Popen(
        [
            binary,
            "--mode",
            "rpc",
            "--session",
            source,
            "--no-context-files",
            "--provider",
            "deepseek",
            "--model",
            "deepseek-v4-flash",
            "--api-key",
            "rpc-clone-key",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        start_new_session=True,
        env=env,
    )
    try:
        proc.stdin.write(json.dumps({"id": "clone", "type": "clone"}) + "\n")
        proc.stdin.flush()
        clone = read_response(proc, "clone")
        if clone.get("success") is not True or clone.get("data", {}).get("cancelled") is not False:
            raise SystemExit(f"RPC clone failed: {clone!r}")

        proc.stdin.write(json.dumps({"id": "state", "type": "get_state"}) + "\n")
        proc.stdin.flush()
        state_response = read_response(proc, "state")
        if state_response.get("success") is not True:
            raise SystemExit(f"clone state query failed: {state_response!r}")
        state = state_response.get("data", {})
        child = state.get("sessionFile")
        if not child or os.path.realpath(child) == os.path.realpath(source):
            raise SystemExit(f"clone did not switch to a new session file: {state!r}")
        if not os.path.exists(child):
            raise SystemExit(f"clone session file does not exist: {child}")
        with open(child, encoding="utf-8") as cloned:
            header = json.loads(cloned.readline())
            entries = [json.loads(line) for line in cloned if line.strip()]
        if header.get("parentSession") != source:
            raise SystemExit(f"clone header lost parentSession: {header!r}")
        if [entry.get("type") for entry in entries] != [entry["type"] for entry in seed[1:]]:
            raise SystemExit(f"clone did not retain the active branch: {entries!r}")
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=3)
        if proc.returncode not in (0,):
            error = proc.stderr.read()
            if error:
                sys.stderr.write(error)

print("e2e: RPC clone preserves the active branch and parent session like Pi OK")
PY
