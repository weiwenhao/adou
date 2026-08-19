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
import time

binary = sys.argv[1]

with tempfile.TemporaryDirectory(prefix="adou-rpc-abort-bash-") as root:
    env = os.environ.copy()
    env.update(
        {
            "ADOU_CODING_AGENT_DIR": os.path.join(root, "agent"),
            "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
        }
    )
    command = [
        binary,
        "--mode",
        "rpc",
        "--no-session",
        "--no-context-files",
        "--provider",
        "deepseek",
        "--model",
        "deepseek-v4-flash",
        "--thinking",
        "off",
        "--api-key",
        "rpc-abort-bash-key",
    ]
    proc = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        start_new_session=True,
        env=env,
    )
    seen = []
    try:
        proc.stdin.write(
            json.dumps(
                {
                    "id": "bash-1",
                    "type": "bash",
                    "command": "sleep 5; printf should-not-run",
                },
                separators=(",", ":"),
            )
            + "\n"
        )
        proc.stdin.flush()
        time.sleep(0.15)
        proc.stdin.write(json.dumps({"id": "abort-1", "type": "abort_bash"}) + "\n")
        proc.stdin.flush()

        deadline = time.monotonic() + 8
        bash_response = None
        abort_response = None
        while time.monotonic() < deadline:
            readable, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not readable:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            item = json.loads(line)
            seen.append(item)
            if item.get("type") == "response" and item.get("id") == "abort-1":
                abort_response = item
            if item.get("type") == "response" and item.get("id") == "bash-1":
                bash_response = item
                break

        if abort_response is None or abort_response.get("success") is not True:
            raise SystemExit(f"abort_bash response missing or failed: {seen!r}")
        if bash_response is None or bash_response.get("success") is not True:
            raise SystemExit(f"cancelled bash response missing or failed: {seen!r}")
        data = bash_response.get("data")
        if not isinstance(data, dict) or data.get("cancelled") is not True:
            raise SystemExit(f"bash result was not marked cancelled: {bash_response!r}")
        if "exitCode" in data or "fullOutputPath" in data:
            raise SystemExit(f"cancelled Bash result contains Pi-undefined fields: {bash_response!r}")
        if "should-not-run" in data.get("output", ""):
            raise SystemExit(f"cancelled bash produced post-abort output: {bash_response!r}")
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

print("e2e: RPC abort_bash cancels only the active Bash operation OK")
PY
