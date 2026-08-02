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

with tempfile.TemporaryDirectory(prefix="adou-rpc-bash-stream-") as root:
    env = os.environ.copy()
    env.update(
        {
            "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
            "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
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
        "rpc-bash-stream-key",
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
                    "command": "printf first; sleep 0.15; printf second",
                },
                separators=(",", ":"),
            )
            + "\n"
        )
        proc.stdin.flush()

        deadline = time.monotonic() + 10
        response = None
        while time.monotonic() < deadline:
            readable, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not readable:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            item = json.loads(line)
            seen.append(item)
            if item.get("type") == "response" and item.get("id") == "bash-1":
                response = item
                break

        if response is None:
            raise SystemExit(f"did not receive bash response: {seen!r}")
        if response.get("success") is not True:
            raise SystemExit(f"bash request failed: {response!r}")

        updates = [item for item in seen if item.get("type") == "bash_execution_update"]
        if not updates:
            raise SystemExit(f"Pi bash_execution_update event missing: {seen!r}")
        if any(item.get("id") != "bash-1" for item in updates):
            raise SystemExit(f"bash update id mismatch: {updates!r}")
        if any("delta" not in item or "command" in item or "output" in item for item in updates):
            raise SystemExit(f"bash update payload is not Pi-shaped: {updates!r}")
        streamed = "".join(item["delta"] for item in updates)
        if "first" not in streamed or "second" not in streamed:
            raise SystemExit(f"bash output was not streamed in deltas: {updates!r}")

        data = response.get("data")
        if not isinstance(data, dict) or data.get("output") != "firstsecond":
            raise SystemExit(f"final bash result mismatch: {response!r}")
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

print("e2e: RPC bash streams Pi bash_execution_update deltas before the final result OK")
PY
