#!/bin/sh
set -eu

# TUI Unicode cursor regression, per-grapheme sensitive.  The old bug
# (ANSI cursor styling inserted at a display-column offset inside a UTF-8
# code point) only surfaces when the caret sits mid-line; typing to EOL
# masked it.  This test writes every grapheme individually, waits for each
# redraw, moves the caret back one grapheme (forcing mid-line rendering),
# and asserts the grapheme's raw bytes remain contiguous with no
# replacement characters -- for 你好, a+U+0301, ZWJ 👨\u200d💻 and 🇨🇳.
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
import select
import shutil
import signal
import struct
import tempfile
import termios
import time

binary = os.environ["ADOU_BIN"]
root = tempfile.mkdtemp(prefix="adou-tui-unicode-")

env = os.environ.copy()
env.update(
    {
        "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
        "PI_TUI_WRITE_LOG": os.path.join(root, "write.log"),
    }
)
os.makedirs(os.path.join(root, "agent"), exist_ok=True)
open(os.path.join(root, "agent", ".adou-setup"), "w").close()

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(binary, [binary, "--offline", "--no-context-files", "--no-session"], env)

output = bytearray()
status = None


def collect(timeout=1.0):
    global status
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.01)
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


def type_grapheme(grapheme):
    # Wait for any redraw after the write; do NOT wait for the grapheme
    # bytes to appear contiguously -- the pre-fix binary renders them split
    # by ANSI, so contiguity is asserted separately with a precise message.
    os.write(fd, grapheme.encode("utf-8"))
    before = len(output)
    deadline = time.time() + 8.0
    while time.time() < deadline:
        collect(timeout=0.05)
        if len(output) > before:
            return
    raise SystemExit(f"grapheme {grapheme!r} produced no redraw (input lost or TUI stalled)")


def move_left():
    os.write(fd, b"\x1b[D")
    collect(timeout=0.3)


def move_right():
    os.write(fd, b"\x1b[C")
    collect(timeout=0.3)


def check_contiguous(label, grapheme, data):
    raw = grapheme.encode("utf-8")
    if raw not in data:
        # Precise diagnosis: find whether the grapheme bytes appear split by
        # an ESC sequence (the classic ANSI-inside-code-point corruption).
        ctx = []
        idx = data.find(raw[:1])
        if idx >= 0:
            ctx = data[max(0, idx - 4): idx + 24]
        raise SystemExit(
            f"{label}: UTF-8/ANSI split detected -- grapheme {grapheme!r} "
            f"bytes {raw.hex()} not contiguous; context: {ctx.hex()}"
        )
    if b"\xef\xbf\xbd" in data:
        raise SystemExit(f"{label}: replacement character present in TUI output")


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    collect(timeout=2.0)

    cases = [
        ("hanzi", "\u4f60\u597d"),                # 你好
        ("combining", "a\u0301"),                  # a + combining acute
        ("zwj", "\U0001F468\u200d\U0001F4BB"),    # 👨\u200d💻
        ("flag", "\U0001F1E8\U0001F1F3"),         # 🇨🇳
    ]

    for label, text in cases:
        if label == "hanzi":
            type_grapheme(text[0])
            type_grapheme(text[1])
        else:
            type_grapheme(text)
        # Move the caret one grapheme back so the cursor renders mid-line;
        # the old bug only cut into a code point at a mid-line caret.
        move_left()
        collect(timeout=0.3)
        check_contiguous(label, text, bytes(output))
        move_right()

    # Final full-buffer sanity: the trailing grapheme sequence stays intact.
    data = bytes(output)
    for label, text in cases:
        check_contiguous(label, text, data)

    print("unicode echo OK: per-grapheme writes stay contiguous on code point boundaries")

    os.write(fd, b"\x03")
    collect(timeout=1.0)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
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

echo "e2e: TUI typed UTF-8 stays on code point boundaries (per-grapheme)"
