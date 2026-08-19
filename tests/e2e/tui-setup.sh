#!/bin/sh
set -eu

# PTY e2e for the first-time setup: the welcome overlay appears once, the
# theme and telemetry entries toggle, Continue writes the marker, and a
# second run skips the welcome.
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
root = tempfile.mkdtemp(prefix="adou-tui-setup-")
env = os.environ.copy()
env.update(
    {
        "ADOU_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
    }
)


def spawn():
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(
            binary,
            [binary, "--offline", "--no-context-files", "--no-session",
             "--provider", "deepseek", "--model", "deepseek-v4-flash"],
            env,
        )
    return pid, fd


pid, fd = spawn()
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


def teardown():
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
            os.waitpid(pid, 0)
        except OSError:
            pass


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))

    # First launch: the welcome overlay shows with theme and telemetry.
    if not collect(b"Welcome to Adou", timeout=5.0):
        raise SystemExit("first-time setup did not open on the first launch")
    collect(timeout=0.3)
    if b"Theme: dark" not in bytes(output) or b"Telemetry: off" not in bytes(output):
        raise SystemExit("setup entries missing")

    # Toggle the theme entry for a live preview.
    if not key(b"\r", b"Theme: light", timeout=4.0):
        raise SystemExit("setup theme toggle did not preview the light variant")

    # Complete the setup: the marker file is written and the TUI quits.
    os.write(fd, b"\x1b[B")
    time.sleep(0.3)
    os.write(fd, b"\x1b[B")
    time.sleep(0.3)
    if not key(b"\r", b"Setup complete", timeout=4.0):
        raise SystemExit("Continue did not complete the setup")
    marker = os.path.join(root, "agent", ".adou-setup")
    if not os.path.exists(marker):
        raise SystemExit("setup marker file was not written")
    os.write(fd, b"/quit\r")
    collect(timeout=6.0)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
finally:
    teardown()

# Second launch: the welcome must be skipped.
pid2, fd2 = pty.fork()
if pid2 == 0:
    os.execvpe(binary, [binary, "--offline", "--no-context-files", "--no-session",
                        "--provider", "deepseek", "--model", "deepseek-v4-flash"], env)
output2 = bytearray()
status2 = None
try:
    def collect2(until=None, timeout=4.0):
        global status2
        deadline = time.time() + timeout
        while time.time() < deadline:
            if until is not None and until in output2:
                return True
            ready, _, _ = select.select([fd2], [], [], 0.05)
            if ready:
                try:
                    output2.extend(os.read(fd2, 65536))
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
            waited, child_status = os.waitpid(pid2, os.WNOHANG)
            if waited:
                status2 = child_status
                break
        return until is not None and until in output2

    fcntl.ioctl(fd2, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    if not collect2(b"\x1b[>1u", timeout=10.0):
        raise SystemExit("restarted TUI did not become ready for keyboard input")
    if b"Welcome to Adou" in bytes(output2):
        raise SystemExit("setup reopened after the marker was written")
    os.write(fd2, b"/quit\r")
    collect2(timeout=6.0)
finally:
    try:
        os.close(fd2)
    except OSError:
        pass
    if status2 is None:
        try:
            os.kill(pid2, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(pid2, 0)
        except OSError:
            pass
    shutil.rmtree(root, ignore_errors=True)
PY

echo "e2e: first-time setup shows once and persists its marker"
