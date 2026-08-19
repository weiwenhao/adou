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
import signal
import subprocess
import sys
import tempfile
import time

binary = sys.argv[1]
cwd = os.getcwd()

with tempfile.TemporaryDirectory(prefix="adou-rpc-tree-corrupt-") as root:
    session = os.path.join(root, "corrupt.jsonl")
    entries = [
        {"type": "session", "version": 3, "id": "tree-corrupt", "timestamp": "2026-01-01T00:00:00.000Z", "cwd": cwd},
        {"type": "model_change", "id": "root", "parentId": None, "timestamp": "2026-01-01T00:00:01.000Z", "provider": "deepseek", "modelId": "deepseek-v4-flash"},
        {"type": "model_change", "id": "child", "parentId": "root", "timestamp": "2026-01-01T00:00:02.000Z", "provider": "deepseek", "modelId": "deepseek-v4-flash"},
        {"type": "model_change", "id": "orphan", "parentId": "missing", "timestamp": "2026-01-01T00:00:03.000Z", "provider": "deepseek", "modelId": "deepseek-v4-flash"},
        {"type": "model_change", "id": "self", "parentId": "self", "timestamp": "2026-01-01T00:00:04.000Z", "provider": "deepseek", "modelId": "deepseek-v4-flash"},
        {"type": "model_change", "id": "cycle-a", "parentId": "cycle-b", "timestamp": "2026-01-01T00:00:05.000Z", "provider": "deepseek", "modelId": "deepseek-v4-flash"},
        {"type": "model_change", "id": "cycle-b", "parentId": "cycle-a", "timestamp": "2026-01-01T00:00:06.000Z", "provider": "deepseek", "modelId": "deepseek-v4-flash"},
    ]
    with open(session, "w", encoding="utf-8") as output:
        for entry in entries:
            output.write(json.dumps(entry, separators=(",", ":")) + "\n")

    env = os.environ.copy()
    env.update({"ADOU_CODING_AGENT_DIR": os.path.join(root, "agent"), "ADOU_SESSION_DIR": os.path.join(root, "sessions")})
    proc = subprocess.Popen(
        [binary, "--mode", "rpc", "--session", session, "--no-context-files", "--provider", "deepseek", "--model", "deepseek-v4-flash", "--api-key", "tree-key"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        start_new_session=True,
        env=env,
    )
    try:
        proc.stdin.write(json.dumps({"id": "tree", "type": "get_tree"}) + "\n")
        proc.stdin.flush()
        deadline = time.monotonic() + 5
        response = None
        while time.monotonic() < deadline:
            line = proc.stdout.readline()
            if not line:
                break
            item = json.loads(line)
            if item.get("id") == "tree":
                response = item
                break
        if response is None:
            raise SystemExit("RPC get_tree did not return for malformed parent data")
        if response.get("success") is not True:
            raise SystemExit(f"RPC get_tree failed: {response!r}")
        roots = response.get("data", {}).get("tree", [])
        root_ids = [node.get("entry", {}).get("id") for node in roots]
        if root_ids != ["root", "orphan", "self"]:
            raise SystemExit(f"Pi root handling mismatch: {root_ids!r}")
        root_children = roots[0].get("children", [])
        if [node.get("entry", {}).get("id") for node in root_children] != ["child"]:
            raise SystemExit(f"child tree mismatch: {root_children!r}")
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

print("e2e: RPC get_tree handles orphan, self-parent, and cyclic session entries like Pi OK")
PY
