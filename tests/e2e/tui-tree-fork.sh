#!/bin/sh
set -eu

# PTY e2e closing Phase 5: /tree overlay (open, cancel, non-leaf navigate),
# branch-summary choice (No summary completes navigation), /fork overlay
# (choose a user message, fork to a new session), and terminal restore on
# quit.  All assertions run against a deterministic seeded JSONL session.
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
root = tempfile.mkdtemp(prefix="adou-tui-tree-fork-")
sessions = os.path.join(root, "sessions")
os.makedirs(sessions)
cwd = os.getcwd()

entries = [
    {"type": "session", "version": 3, "id": "seed-root", "timestamp": "2026-01-01T00:00:00.000Z", "cwd": cwd},
    {"type": "session_info", "id": "seed-root-s", "parentId": None, "timestamp": "2026-01-01T00:00:01.000Z", "name": "main"},
    {"type": "label", "id": "seed-label", "parentId": None, "timestamp": "2026-01-01T00:00:01.500Z", "targetId": "seed-user", "label": "main"},
    {
        "type": "message",
        "id": "seed-user",
        "parentId": None,
        "timestamp": "2026-01-01T00:00:02.000Z",
        "message": {"role": "user", "content": "please inspect the session tree flow", "timestamp": 1},
    },
    {
        "type": "message",
        "id": "seed-assistant",
        "parentId": "seed-user",
        "timestamp": "2026-01-01T00:00:03.000Z",
        "message": {"role": "assistant", "content": [{"type": "text", "text": "tree navigation inspected"}], "timestamp": 2},
    },
]
with open(os.path.join(sessions, "2026-01-01T00-00-00_seed-root.jsonl"), "w", encoding="utf-8") as out:
    for entry in entries:
        out.write(json.dumps(entry, separators=(",", ":")) + "\n")

env = os.environ.copy()
env.update(
    {
        "ADOU_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "ADOU_SESSION_DIR": sessions,
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
            "--session-id",
            "seed-root",
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


def send(data, until, timeout=4.0):
    os.write(fd, data)
    time.sleep(0.08)
    return collect(until, timeout=timeout)


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    if not collect(b"\x1b[>1u", timeout=10.0):
        raise SystemExit("TUI did not become ready for keyboard input")

    # 1. /trust opens the project selector, supports j/k navigation and
    # cancel, then applies a session-only decision without writing a store.
    if not send(b"/trust\r", b"Project trust:", timeout=5.0):
        raise SystemExit("/trust did not open the project trust selector")
    collect(timeout=0.3)
    if b"Trust (this session only)" not in output or b"Saved source:" not in output:
        raise SystemExit("trust selector is missing session/source state")
    if not send(b"j", None, timeout=2.0):
        pass
    if not send(b"k", None, timeout=2.0):
        pass
    os.write(fd, b"\x1b")
    time.sleep(0.3)
    if not send(b"/trust\r", b"Project trust:", timeout=5.0):
        raise SystemExit("/trust did not reopen after cancel")
    os.write(fd, b"\x1b[B" * 2)
    time.sleep(0.15)
    if not send(b"\r", b"for this session", timeout=5.0):
        raise SystemExit("session-only trust choice did not apply")

    # 2. /tree opens the overlay with the seeded entries and the label.
    if not send(b"/tree\r", b"Session tree:", timeout=5.0):
        raise SystemExit("/tree did not open the session tree overlay")
    collect(timeout=0.4)
    if b"[main]" not in output:
        raise SystemExit("session label missing from the tree overlay")
    if b"seed-user" not in output or b"seed-assistant" not in output:
        raise SystemExit("tree overlay lacks the seeded message entries")
    # The fixture is intentionally old, so a real epoch conversion must
    # render a day-based age rather than the fallback "just now".
    if not send(b"\x1b[116;2u", b"d ago", timeout=4.0):
        raise SystemExit("tree timestamp toggle did not render a relative age")
    # Select the parent message and exercise fold/unfold.  A folded parent
    # remains visible with a '+' marker while only its descendant disappears.
    os.write(fd, b"\x1b")
    time.sleep(0.005)
    os.write(fd, b"[A")
    time.sleep(0.2)
    if not send(b"\x1b[1;3D", b"+ seed-assistant", timeout=4.0):
        raise SystemExit("tree fold did not preserve the collapsed parent row")
    send(b"\x1b[1;3C", None, timeout=2.0)
    # Tree copy and page navigation are overlay-local actions; the copy uses
    # OSC-52 and must leave the selector open with a visible status.
    if not send(b"\x18", b"Copied tree entry to clipboard", timeout=4.0):
        raise SystemExit("tree copy action did not reach the clipboard path")
    send(b"\x1b[6~", None, timeout=2.0)
    send(b"\x1b[5~", None, timeout=2.0)

    # 3. Escape cancels the tree overlay without crashing, then /tree reopens.
    if not send(b"\x1b", None, timeout=2.0):
        pass
    time.sleep(0.4)
    if not send(b"/tree\r", b"Session tree:", timeout=5.0):
        raise SystemExit("/tree did not reopen after escape")

    # 4. Arrow-up selects the non-leaf user message (the 50 ms escape window
    #    absorbs PTY-split sequences), then the branch-summary dialog
    #    completes with "No summary" (offline mode: no provider round-trip).
    os.write(fd, b"\x1b")
    time.sleep(0.005)
    os.write(fd, b"[A")
    time.sleep(0.3)
    if not send(b"\r", b"Summarize branch?", timeout=4.0):
        raise SystemExit("selecting a non-leaf entry did not open the branch summary dialog")
    if not send(b"\r", b"Navigated to selected point", timeout=4.0):
        raise SystemExit("No summary did not complete the tree navigation")

    # 5. Clear the editor text that tree navigation inserted, then /fork
    #    lists user messages and forks the selected one.
    os.write(fd, b"\x7f" * 64)
    time.sleep(0.3)
    if not send(b"/fork\r", b"Fork from user message:", timeout=5.0):
        raise SystemExit("/fork did not open the fork overlay")
    collect(timeout=0.4)
    if b"please inspect the session tree flow" not in output:
        raise SystemExit("fork overlay lacks the seeded user message preview")
    if not send(b"\r", b"Forked to new session", timeout=5.0):
        raise SystemExit("fork selection did not create a new session")

    # 6. Clear the editor text fork inserted, then clean quit restores the
    #    terminal and exits 0.
    os.write(fd, b"\x7f" * 64)
    time.sleep(0.3)
    send(b"/quit\r", None, timeout=6.0)
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

echo "e2e: tree, branch summary and fork flows complete in a PTY with terminal restore"
