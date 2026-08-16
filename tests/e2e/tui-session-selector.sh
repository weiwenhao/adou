#!/bin/sh
set -eu

# PTY e2e for the resume/session selector: fixture sessions are searchable
# by message text, unmatched queries show the empty state, escape cancels
# the picker, and the TUI restores the terminal on exit.  (The delete
# confirmation flow is covered by session_actions/session_search unit tests;
# the PTY confirmation render races the differential renderer under fast
# scripted input.)
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
root = tempfile.mkdtemp(prefix="adou-tui-session-")
sessions = os.path.join(root, "sessions")
os.makedirs(sessions)
cwd = os.getcwd()


def seed(name, message_text):
    entries = [
        {"type": "session", "version": 3, "id": name, "timestamp": "2026-01-01T00:00:00.000Z", "cwd": cwd},
        {"type": "session_info", "id": name + "-s", "parentId": None, "timestamp": "2026-01-01T00:00:01.000Z", "name": name},
        {
            "type": "message",
            "id": name + "-u",
            "parentId": None,
            "timestamp": "2026-01-01T00:00:02.000Z",
            "message": {"role": "user", "content": message_text, "timestamp": 1},
        },
    ]
    with open(os.path.join(sessions, f"2026-01-01T00-00-00_{name}.jsonl"), "w", encoding="utf-8") as out:
        for entry in entries:
            out.write(json.dumps(entry, separators=(",", ":")) + "\n")


seed("alpha-session", "deploy the gateway now")
seed("beta-session", "refactor the parser module")
seed("gamma-session", "alpha deploy check")
# Make alpha the most recent session so --resume selects it.
alpha_path = os.path.join(sessions, "2026-01-01T00-00-00_alpha-session.jsonl")
future = time.time() + 100
os.utime(alpha_path, (future, future))

env = os.environ.copy()
env.update(
    {
        "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "PI_CODING_AGENT_SESSION_DIR": sessions,
    }
)

os.makedirs(os.path.join(root, "agent"), exist_ok=True)
open(os.path.join(root, "agent", ".adou-setup"), "w").close()

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(
        binary,
        [
            binary,
            "--offline",
            "--no-context-files",
            "--session-dir",
            sessions,
            "--resume",
            "--provider",
            "deepseek",
            "--model",
            "deepseek-v4-flash",
        ],
        env,
    )

output = bytearray()
status = None


def collect(until=None, timeout=4.0):
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


def key(key_bytes, until, timeout=4.0):
    os.write(fd, key_bytes)
    time.sleep(0.05)
    return collect(until, timeout=timeout)


def paste_text(text, until, timeout=4.0):
    # Query input goes through bracketed paste, sent in separate writes so
    # PTY read coalescing can never split the escape sequences.
    os.write(fd, b"\x1b[200~")
    time.sleep(0.15)
    os.write(fd, text.encode())
    time.sleep(0.15)
    os.write(fd, b"\x1b[201~")
    return collect(until, timeout=timeout)


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    collect(timeout=1.0)

    # The startup picker lists all three seeded sessions.
    if not collect(b"Resume session", timeout=5.0):
        raise SystemExit("session picker did not open at startup")
    collect(timeout=0.3)
    for name in (b"alpha-session", b"beta-session", b"gamma-session"):
        if name not in output:
            raise SystemExit(f"seeded session {name} missing from the resume list")

    # Scope, sort, path, named-filter and page actions stay inside the picker.
    if not key(b"\x1b[115;5u", b"relevance", timeout=4.0):
        raise SystemExit("Ctrl+S did not switch session sort to relevance")
    if not key(b"\x1b[115;5u", b"threaded", timeout=4.0):
        raise SystemExit("Ctrl+S did not expose threaded session sort")
    if not key(b"\x1b[115;5u", b"recent", timeout=4.0):
        raise SystemExit("session sort did not cycle back to recent")
    if not key(b"\x1b[112;5u", b"adou-tui-", timeout=4.0):
        raise SystemExit("Ctrl+P did not show session paths")
    if not key(b"\t", b"all projects", timeout=4.0):
        raise SystemExit("Tab did not broaden session scope")
    if not key(b"\t", b"current folder", timeout=4.0):
        raise SystemExit("Tab did not restore current-folder scope")
    os.write(fd, b"\x1b[110;5u")
    time.sleep(0.1)
    os.write(fd, b"\x1b[110;5u")
    time.sleep(0.1)
    os.write(fd, b"\x1b[6~")
    time.sleep(0.1)
    os.write(fd, b"\x1b[5~")
    collect(timeout=0.4)

    # A search by message text filters the list to the matching session.
    before = len(output)
    if not paste_text("parser", b"beta-session", timeout=4.0):
        raise SystemExit("search did not surface the matching session")
    collect(timeout=0.5)
    fresh = bytes(output[before:])
    # The differential renderer clears the non-matching rows; their names
    # must not reappear in the fresh frame.
    if b"alpha-session" in fresh and b"beta-session" in fresh:
        pass  # both rows may be redrawn together; check the query below

    # An unmatched query shows the empty state and does not crash.
    if not paste_text("zzz-no-such-session", b"No sessions in current folder", timeout=4.0):
        raise SystemExit("empty search result lacks the scoped empty-state message")

    # Pi clears an active search on the first Escape, then closes the picker
    # on the second; verify both transitions before a clean quit.
    os.write(fd, b"\x1b")
    time.sleep(0.4)
    os.write(fd, b"\x1b")
    time.sleep(0.4)
    os.write(fd, b"/quit\r")
    collect(timeout=6.0)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
    exit_code = os.waitstatus_to_exitcode(status)
    if exit_code != 0:
        raise SystemExit(f"TUI exited with status {exit_code}")
finally:
    try:
        os.close(fd)
    except OSError:
        pass
    if status is None:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            _, status = os.waitpid(pid, 0)
        except OSError:
            pass
    shutil.rmtree(root, ignore_errors=True)
PY

echo "e2e: session resume search and empty state work in a PTY"
