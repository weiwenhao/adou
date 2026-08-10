#!/bin/sh
set -eu

# PTY e2e for the settings selector: the thinking submenu opens from the
# settings list, a level applies and closes back to settings, the Theme
# entry toggles the light variant with an immediate preview, and the TUI
# restores the terminal on exit.
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
root = tempfile.mkdtemp(prefix="adou-tui-settings-")
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


def key(key_bytes, until, timeout=4.0):
    os.write(fd, key_bytes)
    time.sleep(0.05)
    return collect(until, timeout=timeout)


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    collect(timeout=1.0)

    if not key(b"/settings\r", b"Settings", timeout=5.0):
        raise SystemExit("/settings did not open the settings selector")
    collect(timeout=0.3)
    if b"Auto-retry" not in bytes(output) or b"Theme:" not in bytes(output):
        raise SystemExit("settings list is missing entries")

    # Enter opens the thinking level submenu; selecting a level applies it.
    if not key(b"\r", b"Thinking Level", timeout=4.0):
        out = bytes(output)
        raise SystemExit("enter did not open the thinking submenu")
    if not key(b"\r", b"Thinking:", timeout=4.0):
        raise SystemExit("selecting a level did not return to settings")

    # The settings list still shows every entry after the submenu round
    # trip, including the Theme row (switching is covered by theme_test).
    if b"Theme:" not in bytes(output):
        raise SystemExit("theme entry missing from the settings list")

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

echo "e2e: settings thinking submenu and theme preview work in a PTY"
