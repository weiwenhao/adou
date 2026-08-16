#!/bin/sh
set -eu

# PTY e2e for Pi's scoped-models three-state contract:
# absent enabledModels = all, an explicit ordered list may be empty, changes
# are session-only until Ctrl+S, and Escape never persists them implicitly.
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

root = tempfile.mkdtemp(prefix="adou-tui-scoped-")
repo = os.getcwd()
sys.path.insert(0, os.path.join(repo, "tests", "e2e", "lib"))
from pty_protocol import PtyCase, fixed_oracle_env

binary = os.environ["ADOU_BIN"]
home = os.path.join(root, "home")
agent = os.path.join(root, "agent")
sessions = os.path.join(root, "sessions")
settings_path = os.path.join(agent, "settings.json")
os.makedirs(agent, exist_ok=True)
os.makedirs(home, exist_ok=True)
open(os.path.join(agent, ".adou-setup"), "w").close()
with open(settings_path, "w", encoding="utf-8") as handle:
    json.dump({"enabledModels": ["deepseek/deepseek-v4-flash"]}, handle)

env = fixed_oracle_env(home, agent_dir=agent)
env.update(
    {
        "PI_CODING_AGENT_SESSION_DIR": sessions,
        "PI_OFFLINE": "1",
        "DEEPSEEK_API_KEY": "test-key",
    }
)
argv = [
    binary,
    "--offline",
    "--no-context-files",
    "--no-session",
    "--provider",
    "deepseek",
    "--model",
    "deepseek-v4-flash",
]


def start():
    case = PtyCase(argv, env, repo, rows=24, cols=100, ready_marker=b"\x1b[>1u")
    case.start()
    case.wait_ready(timeout=15.0)
    case.drain(timeout=8.0)
    return case


def send(case, data):
    case.mark_input()
    case.send_sequence(data, per_key=0.025)
    case.drain_after_input(quiet=0.35, timeout=8.0, no_output_hold=0.5)


def require_screen(case, text, context):
    screen = case.screen_text()
    if text not in " ".join(screen.split()):
        raise SystemExit(f"{context}: missing {text!r}\n{screen}")


def read_settings():
    with open(settings_path, encoding="utf-8") as handle:
        return json.load(handle)


try:
    first = start()
    try:
        send(first, b"/scoped-models\r")
        require_screen(first, "Model Configuration", "open selector")
        require_screen(first, "1/2 enabled", "configured single-model scope")

        send(first, b"\x18")
        require_screen(first, "0/2 enabled", "clear-all session state")
        require_screen(first, "(unsaved)", "dirty session state")
        send(first, b"\x1b")
        if read_settings().get("enabledModels") != ["deepseek/deepseek-v4-flash"]:
            raise SystemExit("Escape persisted scoped-model changes")

        send(first, b"/scoped-models\r")
        require_screen(first, "0/2 enabled", "session-only empty scope after reopen")
        require_screen(first, "(unsaved)", "dirty state after reopen")
        send(first, b"\x13")
        if read_settings().get("enabledModels") != []:
            raise SystemExit("Ctrl+S did not persist explicit empty enabledModels")
        if "(unsaved)" in first.screen_text():
            raise SystemExit("Ctrl+S did not clear the dirty marker")
        send(first, b"\x1b")
        first.send_bytes(b"/quit\r")
        if first.wait_exit(8.0) != 0:
            raise SystemExit("first scoped-model session did not exit cleanly")
    finally:
        first.close()

    second = start()
    try:
        send(second, b"/scoped-models\r")
        require_screen(second, "0/2 enabled", "explicit empty scope after process reload")
        if "(unsaved)" in second.screen_text():
            raise SystemExit("persisted empty scope reopened as dirty")
        send(second, b"\x01")
        require_screen(second, "all enabled", "enable-all null state")
        send(second, b"\x13")
        if "enabledModels" in read_settings():
            raise SystemExit("saving all-enabled did not remove enabledModels")
        send(second, b"\x1b")
        second.send_bytes(b"/quit\r")
        if second.wait_exit(8.0) != 0:
            raise SystemExit("second scoped-model session did not exit cleanly")
    finally:
        second.close()
finally:
    shutil.rmtree(root, ignore_errors=True)
PY

echo "e2e: scoped models all/explicit-empty/dirty/save/cancel/reload contract works in a PTY"
