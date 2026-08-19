#!/bin/sh
set -eu

# A slash autocomplete menu is transient UI. With clearOnShrink disabled (the
# default), deleting the slash must still erase the removed candidate rows.
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

ADOU_BIN="$binary" python3 - <<'PY'
import json
import os
import shutil
import sys
import tempfile

binary = os.environ["ADOU_BIN"]
sys.path.insert(0, os.path.join(os.getcwd(), "tests", "e2e", "lib"))
from pty_protocol import PtyCase, fixed_oracle_env

root = tempfile.mkdtemp(prefix="adou-autocomplete-cleanup-")
home = os.path.join(root, "home")
agent = os.path.join(root, "agent")
cwd = os.path.join(root, "cwd")
os.makedirs(home)
os.makedirs(agent)
os.makedirs(cwd)
open(os.path.join(agent, ".adou-setup"), "w").close()
with open(os.path.join(agent, "settings.json"), "w") as handle:
    json.dump({"terminal": {"clearOnShrink": False}}, handle)

env = fixed_oracle_env(home, agent_dir=agent)
env["DEEPSEEK_API_KEY"] = "test-key"
env["ADOU_OFFLINE"] = "1"
case = PtyCase(
    [
        binary,
        "--offline",
        "--no-context-files",
        "--no-session",
        "--provider",
        "deepseek",
        "--model",
        "deepseek-v4-flash",
    ],
    env,
    cwd,
    rows=24,
    cols=100,
    ready_marker=b"\x1b[>1u",
)

try:
    case.start()
    case.wait_ready(timeout=10.0)
    case.drain(quiet=0.2, timeout=5.0)

    case.mark_input()
    case.send_bytes(b"/")
    case.drain_after_input(quiet=0.2, timeout=5.0)
    opened = case.screen_text()
    if "scoped-models" not in opened or "Export session" not in opened:
        raise SystemExit("slash autocomplete menu did not open")

    case.mark_input()
    case.send_bytes(b"\x7f")
    case.drain_after_input(quiet=0.2, timeout=5.0)
    closed = case.screen_text()
    residue = [
        marker
        for marker in (
            "scoped-models",
            "Enable/disable models",
            "Export session",
            "Import and resume",
            "(1/",
        )
        if marker in closed
    ]
    if residue:
        raise SystemExit(f"deleted slash left autocomplete residue: {residue}")

    case.send_sequence(b"/quit\r", per_key=0.02)
    code = case.wait_exit(timeout=10.0)
    if code != 0:
        raise SystemExit(f"TUI exited with status {code}")
finally:
    case.close()
    shutil.rmtree(root, ignore_errors=True)
PY

echo "e2e: deleting slash clears autocomplete rows with clearOnShrink disabled"
