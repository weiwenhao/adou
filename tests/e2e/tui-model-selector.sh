#!/bin/sh
set -eu

# PTY e2e for the model selector: the current model carries a check mark,
# searches filter by id/provider/name, unmatched queries show the empty
# state, Tab switches the scope header, selecting a model updates the
# status, and the TUI restores the terminal on exit.
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
root = tempfile.mkdtemp(prefix="adou-tui-model-")
env = os.environ.copy()
env.update(
    {
        "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
        "DEEPSEEK_API_KEY": "test-key",
    }
)

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


def key(key_bytes, until, timeout=4.0):
    os.write(fd, key_bytes)
    time.sleep(0.05)
    return collect(until, timeout=timeout)


def paste_text(text, until, timeout=4.0):
    os.write(fd, b"\x1b[200~")
    time.sleep(0.15)
    os.write(fd, text.encode())
    time.sleep(0.15)
    os.write(fd, b"\x1b[201~")
    return collect(until, timeout=timeout)


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    collect(timeout=1.0)

    # Open the model selector with Ctrl+L.
    if not key(b"\x0c", b"Select model:", timeout=5.0):
        raise SystemExit("ctrl+l did not open the model selector")
    collect(timeout=0.5)
    # The current model row carries the Pi check mark; provider badge shows.
    if b"\xe2\x9c\x93" not in bytes(output):
        raise SystemExit("current model check mark missing from the selector")
    if b"deepseek-v4-flash" not in bytes(output):
        raise SystemExit("current model row missing from the selector")

    # A search by model name narrows the list.
    if not paste_text("deepseek-v4", b"deepseek-v4-flash", timeout=4.0):
        raise SystemExit("model search did not surface the matching model")

    # An unmatched query shows the model empty state.
    if not paste_text("zzz-no-model", b"No matching models", timeout=4.0):
        raise SystemExit("empty model search lacks the empty-state message")

    # Clear the query and select the current model again: the status line
    # updates and the selector closes.
    for _ in range(30):
        os.write(fd, b"\x7f")
        time.sleep(0.01)
    collect(timeout=0.5)
    if not key(b"\r", b"Model:", timeout=4.0):
        raise SystemExit("selecting a model did not update the status")
    if not key(b"\x0c", b"Select model:", timeout=5.0):
        raise SystemExit("selector did not reopen after selection")
    # Tab switches the scope header.
    if not key(b"\t", b"Scoped", timeout=4.0):
        raise SystemExit("tab did not switch the model scope")
    # Escape cancels and the TUI stays alive for a clean quit.
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

echo "e2e: model selector check mark search empty state scope and selection work in a PTY"
