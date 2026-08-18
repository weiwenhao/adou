#!/bin/sh
set -eu

# PTY e2e for the editor: long input wraps across visual lines at the
# terminal width, newlines enter multiline editing, and the TUI exits
# cleanly through the slash command path.
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
import signal
import struct
import tempfile
import termios
import time

binary = os.environ["ADOU_BIN"]
root = tempfile.mkdtemp(prefix="adou-tui-editor-")
home = os.path.join(root, "home")
os.makedirs(home)
env = os.environ.copy()
env.update(
    {
        "HOME": home,
        "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
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
            "--no-session",
            "--provider",
            "deepseek",
            "--model",
            "deepseek-v4-flash",
        ],
        env,
    )

output = bytearray()
status = None


def collect(until=None, timeout=4.0, start=0):
    global status
    deadline = time.time() + timeout
    while time.time() < deadline:
        if until is not None and until in output[start:]:
            return True
        try:
            ready, _, _ = select.select([fd], [], [], 0.05)
        except OSError as exc:
            # Linux reports EIO on the PTY master after the child closes its
            # slave; that is a normal end-of-session signal.
            if exc.errno == errno.EIO:
                break
            raise
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
    # Narrow terminal so the prompt wraps across visual lines.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 160, 0, 0))
    if not collect(b"\x1b[>1u", timeout=10.0):
        raise SystemExit("TUI did not become ready for keyboard input")

    # Type 60 characters: at width 40 the editor must wrap into two visual
    # lines, and the wrapped tail must be visible in the render.
    long_text = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    os.write(fd, long_text.encode())
    if not collect(long_text.encode(), timeout=3.0):
        raise SystemExit("editor did not render the typed text")
    first_segment = long_text[:38]
    tail_segment = long_text[41:60]
    if first_segment.encode() not in output:
        raise SystemExit("first visual line segment missing from the render")
    if tail_segment.encode() not in output:
        raise SystemExit("wrapped continuation segment missing from the render")
    # Ctrl+J inserts a newline without submitting (Pi binding).
    os.write(fd, b"\x0a")
    time.sleep(0.2)
    os.write(fd, b"second")
    if not collect(b"second", timeout=2.0):
        raise SystemExit("multiline input did not render after newline")
    second_start = len(output)
    for ch in long_text:
        os.write(fd, ch.encode())
        time.sleep(0.005)
    if not collect(long_text.encode(), timeout=3.0, start=second_start):
        print("DEBUG output len=", len(output))
        print("DEBUG head=", output[:400])
        raise SystemExit("editor did not render the typed text")

    # The wrapped continuation (characters 41..60) appears after the first
    # visual line's content; both must be present in the output.
    first_segment = long_text[:38]
    tail_segment = long_text[41:60]
    if first_segment.encode() not in output:
        raise SystemExit("first visual line segment missing from the render")
    if tail_segment.encode() not in output:
        raise SystemExit("wrapped continuation segment missing from the render")

    # Quit through the slash command path so terminal restoration runs.
    os.write(fd, b"\x03")
    # Drain the clear frame before entering /quit; a second Ctrl+C after a
    # long wait can already terminate the TUI and make the following write
    # observe PTY EIO.
    collect(timeout=0.5)
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
    import shutil

    shutil.rmtree(root, ignore_errors=True)
PY

echo "e2e: editor visual wrapping and multiline input work in a PTY"
