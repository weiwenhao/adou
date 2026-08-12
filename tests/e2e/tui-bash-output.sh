#!/bin/sh
set -eu

# PTY e2e for completed bash output: long command output collapses to the
# last visual lines with an expand hint, failed commands show the short
# (exit N) footer, and the TUI exits cleanly through the slash command path.
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
root = tempfile.mkdtemp(prefix="adou-tui-bash-")
env = os.environ.copy()
env.update(
    {
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


def send_and_collect(text, until, timeout=6.0):
    os.write(fd, text.encode())
    return collect(until, timeout=timeout)


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 60, 0, 0))
    collect(timeout=1.0)

    # A long-running command with 80 lines of output: the completed message
    # must collapse to the last visual lines with an expand hint.
    script = "!for i in $(seq 1 80); do echo \"output line $i\"; done"
    if not send_and_collect(script + "\r", b"output line 80", timeout=10.0):
        raise SystemExit("long bash output did not render its tail")
    collect(timeout=0.5)
    if b"more lines, press Ctrl+O to expand" not in output:
        raise SystemExit("collapsed bash output lacks the expand hint")
    # The tail line itself is visible in the render.
    if b"output line 79" not in output:
        raise SystemExit("last output line missing from the render")

    # A failing command shows the short inline exit footer.
    if not send_and_collect("!false\r", b"(exit 1)", timeout=8.0):
        raise SystemExit("failed bash output lacks the (exit 1) footer")

    # Clear the editor and quit through the slash command path.  The restore
    # sequences must be the LAST bytes the TUI writes: a deferred redraw that
    # lands after terminal.restore() would flash a stale frame on the
    # restored terminal (quit-flash regression).
    os.write(fd, b"\x01\x0b")
    time.sleep(0.3)
    os.write(fd, b"/quit\r")
    collect(timeout=6.0)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
    fcntl.fcntl(fd, fcntl.F_SETFL, os.O_NONBLOCK)
    while True:
        try:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            output.extend(chunk)
        except OSError as exc:
            if exc.errno in (errno.EIO, errno.EAGAIN):
                break
            raise
    exit_code = os.waitstatus_to_exitcode(status)
    if exit_code != 0:
        raise SystemExit(f"TUI exited with status {exit_code}")
    if not bytes(output).endswith(b"\x1b[<u\x1b[?2004l\x1b[?25h"):
        raise SystemExit("TUI terminal restore was not its last output (quit-flash regression)")
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

echo "e2e: completed bash output collapses with exit status and truncation hints"
