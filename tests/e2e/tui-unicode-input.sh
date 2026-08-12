#!/bin/sh
set -eu

# TUI Unicode cursor regression: typed UTF-8 must never have ANSI cursor
# styling inserted inside a code point.  The original bug produced
# e5 1b 5b 37 6d a5 (ANSI inside "好"); the byte stream must contain the
# contiguous e4 bd a0 e5 a5 bd for "你好" and never e5 + ESC.
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


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    collect(timeout=2.0)

    # Type 你好 (via bracketed paste so no IME/OS path is involved) and an
    # emoji; the editor must echo them without splitting code points.
    os.write(fd, "\u4f60\u597d\U0001F44D".encode("utf-8"))
    for _ in range(20):
        collect(timeout=0.2)
        if "好".encode("utf-8") in output:
            break

    data = bytes(output)
    nihao = "你好".encode("utf-8")  # e4 bd a0 e5 a5 bd
    if nihao not in data:
        raise SystemExit("typed 你好 missing from TUI output")

    # The original bug: e5 1b ... a5 (ANSI inserted into 好).
    bad = b"\xe5\x1b"
    if bad in data:
        raise SystemExit("ANSI escape inserted inside a UTF-8 code point (e5 1b)")

    # No replacement char either.
    if b"\xef\xbf\xbd" in data:
        raise SystemExit("replacement character present in TUI output")

    print("unicode echo OK: contiguous", nihao.hex(), "present; no split codepoints")

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

echo "e2e: TUI typed UTF-8 stays on code point boundaries"
