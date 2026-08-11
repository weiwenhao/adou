#!/bin/sh
set -eu

# Phase 7 RPC-over-IPC e2e: line-delimited JSON over a localhost TCP socket
# (upstream packages/server ipc protocol).  spawn/list/status/stop manage
# the single instance; rpc prompt honours the offline guard deterministically.
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

ADOU_BIN="$binary" python3 - <<'PY'
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

binary = os.environ["ADOU_BIN"]
root = tempfile.mkdtemp(prefix="adou-ipc-")
port = 18951

env = os.environ.copy()
env.update(
    {
        "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
        "DEEPSEEK_API_KEY": "sk-ipc-test",
    }
)
os.makedirs(os.path.join(root, "agent"), exist_ok=True)

proc = subprocess.Popen(
    [binary, "--serve-port", str(port), "--offline", "--no-context-files", "--provider", "deepseek", "--model", "deepseek-v4-flash", "--thinking", "off"],
    env=env,
)


def request(line, timeout=10.0):
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.sendall((line + "\n").encode())
        data = b""
        while b"\n" not in data:
            data += sock.recv(65536)
        return json.loads(data.split(b"\n")[0])


try:
    deadline = time.time() + 10
    while True:
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=1)
            sock.close()
            break
        except OSError:
            if time.time() > deadline:
                raise SystemExit("ipc server did not come up")
            time.sleep(0.1)

    resp = request('{"type":"spawn","id":"s1","cwd":"/tmp"}')
    if resp.get("type") != "response" or resp.get("success") is not True:
        raise SystemExit(f"spawn failed: {resp!r}")
    instance = resp.get("instanceId", "")
    if not instance:
        raise SystemExit(f"spawn returned no instance id: {resp!r}")

    resp = request('{"type":"list","id":"l1"}')
    if resp.get("success") is not True or resp.get("instanceId") != instance:
        raise SystemExit(f"list failed: {resp!r}")

    resp = request('{"type":"status","id":"t1","instanceId":"' + instance + '"}')
    if resp.get("success") is not True or resp.get("status") != "running":
        raise SystemExit(f"status failed: {resp!r}")

    resp = request('{"type":"rpc","id":"p1","command":{"type":"prompt","message":"hello"}}')
    if resp.get("success") is not False or "Offline mode" not in resp.get("error", ""):
        raise SystemExit(f"offline prompt should fail: {resp!r}")

    resp = request('{"type":"stop","id":"x1","instanceId":"' + instance + '"}')
    if resp.get("success") is not True:
        raise SystemExit(f"stop failed: {resp!r}")

    resp = request('{"type":"rpc","id":"p2","command":{"type":"bogus"}}')
    if resp.get("success") is not False or "Unsupported" not in resp.get("error", ""):
        raise SystemExit(f"unsupported command should fail: {resp!r}")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    shutil.rmtree(root, ignore_errors=True)
PY

echo "e2e: RPC-over-IPC spawn/list/status/stop and offline prompt guard pass"
