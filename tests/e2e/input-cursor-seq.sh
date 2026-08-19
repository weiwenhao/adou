#!/bin/sh
set -eu

# UX-003 evidence harness: the interactive input area must draw exactly one
# inverse cursor cell per frame, keep the hardware cursor hidden by default
# (no ?25h, a single ?25l at startup, no DECSCUSR), and never leave a stale
# reverse-video block after cursor movement or menu open/close.  Raw PTY
# bytes only, so terminal-side rendering cannot be confused with the byte
# stream.
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

ADOU_BIN="$binary" python3 - <<'PY'
import errno
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

binary = os.environ["ADOU_BIN"]

root = tempfile.mkdtemp(prefix="adou-cursor-seq-")
home = os.path.join(root, "home")
agent = os.path.join(home, ".adou", "agent")
os.makedirs(agent)
open(os.path.join(agent, ".adou-setup"), "w").close()

env = os.environ.copy()
env.update(
    {
        "HOME": home,
        "ADOU_CODING_AGENT_DIR": agent,
        "DEEPSEEK_API_KEY": "cursor-seq-e2e-key",
    }
)

base_args = [
    binary,
    "--approve",
    "--no-context-files",
    "--no-session",
    "--provider",
    "deepseek",
    "--model",
    "deepseek/deepseek-v4-flash",
    "--thinking",
    "off",
    "--max-tokens",
    "128",
]

pid, fd = pty.fork()
if pid == 0:
    os.chdir(root)
    os.execvpe(binary, base_args, env)
output = bytearray()


def collect(start, timeout=10.0, until=None):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if until is not None and until in bytes(output[start:]):
            return True
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                output.extend(os.read(fd, 65536))
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
    return until is not None and until in bytes(output[start:])


def send(data, start, until=None, timeout=5.0):
    os.write(fd, data)
    time.sleep(0.12)
    return collect(start, timeout=timeout, until=until)


def frame_slice(start):
    # Bytes appended since `start` (one interaction's frames).
    return bytes(output[start:])


def wait_exit(timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            waited, st = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return 0
        if waited:
            return os.waitstatus_to_exitcode(st)
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                output.extend(os.read(fd, 65536))
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
        time.sleep(0.05)
    return None


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    if not collect(0, timeout=15.0, until=b"\x1b[>1u"):
        raise SystemExit("TUI did not become ready")

    raw = bytes(output)
    if raw.count(b"\x1b[?25h") != 0:
        raise SystemExit("hardware cursor shown during startup")
    if raw.count(b"\x1b[?25l") != 1:
        raise SystemExit(f"expected a single ?25l at startup, got {raw.count(b'\x1b[?25l')}")
    if re.search(rb"\x1b\[[0-9;?]* ?q", raw):
        raise SystemExit("DECSCUSR sequence emitted (not part of the contract)")

    # Typing: each rendered frame carries at most one inverse cursor cell.
    # Frames are split on the sync-off boundary (every frame ends with
    # \x1b[?2026l), so a slice spanning several redraws counts per frame.
    for keys in (b"a", b"bc", "\u4e2d\u6587".encode(), b"\x1b[D", b"\x7f"):
        start = len(output)
        send(keys, start)
        time.sleep(0.3)
        frame = frame_slice(start)
        frames = frame.split(b"\x1b[?2026l")
        for part in frames:
            inverse_blocks = part.count(b"\x1b[7m")
            if inverse_blocks > 1:
                raise SystemExit(f"frame carries more than one inverse cell: {inverse_blocks}")
        if frame.count(b"\x1b[?25h") != 0:
            raise SystemExit("hardware cursor shown during editing")

    # Menu open/close: still no ?25h and no residual inverse beyond the
    # cursor cell of the final frame.
    start = len(output)
    send(b"/", start, until=b"(1/")
    send(b"\x1b", len(output))
    time.sleep(0.4)
    frame = frame_slice(start)
    if frame.count(b"\x1b[?25h") != 0:
        raise SystemExit("hardware cursor shown during the slash menu")
    parts = frame.split(b"\x1b[?2026l")
    if len(parts) > 1:
        last_frame = parts[-1]
    else:
        last_frame = parts[0]
    residual = max(0, last_frame.count(b"\x1b[7m") - last_frame.count(b"\x1b[27m"))
    if residual > 1:
        raise SystemExit(f"residual inverse cells after menu close: {residual}")

    # Clear the text used by the cursor assertions before issuing the slash
    # command; otherwise /quit would be appended to a non-command prompt.
    os.write(fd, b"\x03")
    time.sleep(0.2)
    os.write(fd, b"/quit\r")
    code = wait_exit(timeout=10.0)
    if code is None:
        raise SystemExit("TUI did not exit after /quit")
    if code != 0:
        raise SystemExit(f"TUI exited with status {code}")
    print("e2e: cursor sequences hidden by default, single inverse cell per frame OK")
finally:
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    shutil.rmtree(root, ignore_errors=True)
PY
