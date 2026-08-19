#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

ADOU_BIN="$binary" python3 - <<'PY'
import errno
import fcntl
import json
import os
import pty
import select
import shutil
import signal
import struct
import tempfile
import termios
import time

binary = os.environ["ADOU_BIN"]
root = tempfile.mkdtemp(prefix="adou-share-fake-gh-")
agent = os.path.join(root, "agent")
sessions = os.path.join(root, "sessions")
fake_bin = os.path.join(root, "bin")
gh_log = os.path.join(root, "gh.log")
os.makedirs(agent)
os.makedirs(sessions)
os.makedirs(fake_bin)
open(os.path.join(agent, ".adou-setup"), "w").close()

session_id = "share-fixture"
session_file = os.path.join(sessions, "2026-01-01T00-00-00_share-fixture.jsonl")
entries = [
    {"type": "session", "version": 3, "id": session_id, "timestamp": "2026-01-01T00:00:00.000Z", "cwd": os.getcwd()},
    {"type": "message", "id": "user-1", "parentId": None, "timestamp": "2026-01-01T00:00:01.000Z", "message": {"role": "user", "content": "share fixture request", "timestamp": 1}},
    {"type": "message", "id": "assistant-1", "parentId": "user-1", "timestamp": "2026-01-01T00:00:02.000Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "share fixture response"}], "timestamp": 2}},
]
with open(session_file, "w", encoding="utf-8") as out:
    for entry in entries:
        out.write(json.dumps(entry, separators=(",", ":")) + "\n")

gh = os.path.join(fake_bin, "gh")
with open(gh, "w", encoding="utf-8") as out:
    out.write("""#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$ADOU_FAKE_GH_LOG"
if [ "$1" = auth ] && [ "$2" = status ]; then
    exit 0
fi
if [ "$1" = gist ] && [ "$2" = create ]; then
    target="$4"
    test -s "$target"
    grep -q 'share fixture response' "$target"
    printf '%s\\n' 'https://gist.github.com/weiwenhao/share-fixture-123'
    exit 0
fi
exit 64
""")
os.chmod(gh, 0o700)

env = os.environ.copy()
env.update({
    "ADOU_CODING_AGENT_DIR": agent,
    "ADOU_SESSION_DIR": sessions,
    "ADOU_FAKE_GH_LOG": gh_log,
    "PATH": fake_bin + os.pathsep + env.get("PATH", ""),
    "ADOU_SHARE_VIEWER_URL": "https://viewer.example/session",
})

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(binary, [binary, "--offline", "--no-context-files", "--session", session_file, "--provider", "deepseek", "--model", "deepseek-v4-flash"], env)

output = bytearray()
status = None

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
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    if not collect(b"\x1b[>1u", timeout=10.0):
        raise SystemExit("share PTY did not become ready: " + repr(bytes(output[-1200:])))
    os.write(fd, b"/share\r")
    if not collect(b"Share URL: https://viewer.example/session#share-fixture-123", timeout=8.0):
        calls = []
        if os.path.exists(gh_log):
            with open(gh_log, encoding="utf-8") as raw:
                calls = raw.read().splitlines()
        raise SystemExit("/share did not render the Pi-compatible viewer URL: calls=" + repr(calls) + " output=" + repr(bytes(output[-1800:])))
    collect(timeout=0.3)
    with open(gh_log, encoding="utf-8") as raw:
        calls = raw.read().splitlines()
    if len(calls) != 2 or calls[0] != "auth status" or not calls[1].startswith("gist create --public=false ") or not calls[1].endswith("/session.html"):
        raise SystemExit("fake gh did not receive the expected auth/gist calls: " + repr(calls))
    upload_path = calls[1].split(" ", 3)[-1]
    if os.path.exists(upload_path):
        raise SystemExit("share HTML temporary artifact was not removed")
    os.write(fd, b"/quit\r")
    collect(timeout=6.0)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
    exit_code = os.waitstatus_to_exitcode(status)
    if exit_code != 0:
        raise SystemExit(f"share PTY exited with status {exit_code}")
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
    shutil.rmtree(root, ignore_errors=True)

print("e2e: /share fake-gh artifact, gist arguments, cleanup and viewer URL pass")
PY
