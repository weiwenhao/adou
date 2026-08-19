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
import subprocess
import sys
import tempfile

binary = sys.argv[1]
command = [
    binary,
    "--mode",
    "rpc",
    "--offline",
    "--no-session",
    "--no-context-files",
    "--debug",
]

with tempfile.TemporaryDirectory(prefix="adou-rpc-debug-") as root:
    env = os.environ.copy()
    env.update(
        {
            "ADOU_CODING_AGENT_DIR": os.path.join(root, "agent"),
            "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
            "ADOU_TIMING": "1",
        }
    )
    env.pop("ADOU_DEBUG_FILE", None)
    result = subprocess.run(
        command,
        input=json.dumps({"id": "state", "type": "get_state"}) + "\n",
        text=True,
        capture_output=True,
        timeout=8,
        env=env,
        check=False,
    )

if result.returncode != 0:
    raise SystemExit(f"RPC debug process exited {result.returncode}: {result.stderr}")

lines = [line for line in result.stdout.splitlines() if line.strip()]
try:
    items = [json.loads(line) for line in lines]
except json.JSONDecodeError as exc:
    raise SystemExit(f"debug output polluted RPC stdout: {result.stdout!r}") from exc

responses = [item for item in items if item.get("type") == "response" and item.get("id") == "state"]
if len(responses) != 1 or responses[0].get("success") is not True:
    raise SystemExit(f"get_state response missing or failed: {items!r}")

stderr = result.stderr
if "[adou debug] startup:" not in stderr or "[adou debug] mode: starting rpc loop" not in stderr:
    raise SystemExit(f"debug lifecycle logs missing from stderr: {stderr!r}")
if "--- Startup Timings: main ---" not in stderr or "parseArgs:" not in stderr:
    raise SystemExit(f"ADOU_TIMING output missing from stderr: {stderr!r}")
if "[adou debug]" in result.stdout or "Startup Timings" in result.stdout:
    raise SystemExit(f"diagnostics contaminated RPC stdout: {result.stdout!r}")

print("e2e: debug and startup timings stay on stderr while RPC stdout remains valid JSONL")
PY
