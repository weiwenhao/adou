#!/bin/sh
set -eu

if [ "${ADOU_LIVE_GITHUB_SHARE:-0}" != "1" ]; then
    echo 'e2e: live GitHub share skipped (set ADOU_LIVE_GITHUB_SHARE=1)'
    exit 0
fi

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi
command -v gh >/dev/null 2>&1 || {
    echo 'e2e: live GitHub share requires gh' >&2
    exit 2
}

ADOU_BIN="$binary" python3 - <<'PY'
import errno
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time

binary = os.environ["ADOU_BIN"]
expected_user = os.environ.get("ADOU_GITHUB_USER", "")
active_user = subprocess.run(
    ["gh", "api", "user", "--jq", ".login"],
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()
if expected_user and active_user != expected_user:
    raise SystemExit(
        f"active gh account is {active_user!r}, expected {expected_user!r}"
    )

root = tempfile.mkdtemp(prefix="adou-share-live-gh-")
agent = os.path.join(root, "agent")
sessions = os.path.join(root, "sessions")
os.makedirs(agent)
os.makedirs(sessions)
open(os.path.join(agent, ".adou-setup"), "w").close()

session_file = os.path.join(sessions, "2026-01-01T00-00-00_share-live-fixture.jsonl")
entries = [
    {"type": "session", "version": 3, "id": "share-live-fixture", "timestamp": "2026-01-01T00:00:00.000Z", "cwd": os.getcwd()},
    {"type": "message", "id": "user-1", "parentId": None, "timestamp": "2026-01-01T00:00:01.000Z", "message": {"role": "user", "content": "share fixture request", "timestamp": 1}},
    {"type": "message", "id": "assistant-1", "parentId": "user-1", "timestamp": "2026-01-01T00:00:02.000Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "share fixture response"}], "timestamp": 2}},
]
with open(session_file, "w", encoding="utf-8") as out:
    for entry in entries:
        out.write(json.dumps(entry, separators=(",", ":")) + "\n")

env = os.environ.copy()
env.update(
    {
        "ADOU_CODING_AGENT_DIR": agent,
        "ADOU_SESSION_DIR": sessions,
        "ADOU_SHARE_VIEWER_URL": "https://pi.dev/session/",
    }
)

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(
        binary,
        [
            binary, "--offline", "--no-context-files", "--session", session_file,
            "--provider", "deepseek", "--model", "deepseek-v4-flash",
        ],
        env,
    )

output = bytearray()
status = None
gist_id = ""
success = False


def collect(until=None, timeout=5.0):
    global status
    deadline = time.time() + timeout
    while time.time() < deadline:
        if until is not None and until in output:
            return True
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                output.extend(os.read(fd, 65536))
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
        waited, child_status = os.waitpid(pid, os.WNOHANG)
        if waited:
            status = child_status
            break
    return until is not None and until in output


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 120, 0, 0))
    if not collect(b"\x1b[>1u", timeout=10.0):
        raise RuntimeError("share PTY did not become ready: " + repr(bytes(output[-1200:])))
    os.write(fd, b"/share\r")
    deadline = time.time() + 15
    match = None
    while time.time() < deadline:
        collect(timeout=0.2)
        match = re.search(rb"Share URL: (https://pi\.dev/session/#([0-9a-f]+))", output)
        if match:
            break
    if not match:
        raise RuntimeError("/share did not return a viewer URL: " + repr(bytes(output[-2000:])))
    viewer_url = match.group(1).decode()
    gist_id = match.group(2).decode()

    raw = subprocess.run(
        ["gh", "gist", "view", gist_id, "--raw"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if "share fixture request" not in raw or "share fixture response" not in raw:
        raise RuntimeError("live Gist did not contain the fixture session export")
    public = subprocess.run(
        ["gh", "api", f"gists/{gist_id}", "--jq", ".public"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if public != "false":
        raise RuntimeError(f"live share Gist must be secret, got public={public!r}")
    os.write(fd, b"/quit\r")
    collect(timeout=6.0)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
    exit_code = os.waitstatus_to_exitcode(status)
    if exit_code != 0:
        raise RuntimeError(f"share PTY exited with status {exit_code}")
    success = True
    print(f"LIVE_SHARE_URL={viewer_url}")
    print(f"LIVE_SHARE_GIST_ID={gist_id}")
finally:
    try:
        os.close(fd)
    except OSError:
        pass
    if status is None:
        try:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        except (ChildProcessError, ProcessLookupError, OSError):
            pass
    keep = success and os.environ.get("ADOU_LIVE_GITHUB_KEEP", "0") == "1"
    if gist_id and not keep:
        subprocess.run(
            ["gh", "gist", "delete", gist_id, "--yes"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    shutil.rmtree(root, ignore_errors=True)

print("e2e: live /share secret Gist artifact and viewer URL pass")
PY
