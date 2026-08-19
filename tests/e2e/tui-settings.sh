#!/bin/sh
set -eu

# PTY e2e for the Batch 3 settings selector: the Pi-ordered list shows the
# unavailable image rows, value rows cycle on Enter (transport), the thinking
# submenu still opens from the list, and the transport change persists to
# settings.json.
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
root = tempfile.mkdtemp(prefix="adou-tui-settings-")
agent = os.path.join(root, "agent")
env = os.environ.copy()
env.update(
    {
        "ADOU_CODING_AGENT_DIR": agent,
        "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
    }
)
# This PTY is intercepted by the test process, so it cannot display terminal
# image protocols even when the parent shell is running in Ghostty/Kitty.
# Clear inherited emulator identity to make the unavailable-state assertion
# independent of the developer's terminal.
for key in (
    "TERM_PROGRAM",
    "TERMINAL_EMULATOR",
    "GHOSTTY_RESOURCES_DIR",
    "KITTY_WINDOW_ID",
    "WEZTERM_PANE",
    "WARP_SESSION_ID",
    "WARP_TERMINAL_SESSION_UUID",
    "ITERM_SESSION_ID",
    "WT_SESSION",
    "TMUX",
):
    env.pop(key, None)
env["TERM"] = "xterm-256color"

os.makedirs(agent, exist_ok=True)
open(os.path.join(agent, ".adou-setup"), "w").close()

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


def downs(count):
    for _ in range(count):
        os.write(fd, b"\x1b[B")
        time.sleep(0.12)
    collect(timeout=0.4)


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    if not collect(b"\x1b[>1u", timeout=10.0):
        raise SystemExit("TUI did not become ready for keyboard input")

    if not key(b"/settings\r", b"Settings", timeout=5.0):
        raise SystemExit("/settings did not open the settings selector")
    collect(timeout=0.3)
    # Pi-order list: the top of the list (visible viewport) shows the
    # unavailable image rows and the leading entries.
    for marker in (
        b"Auto-compact:",
        b"Show images: UNAVAILABLE",
        b"Image width: UNAVAILABLE",
        b"Auto-resize images: UNAVAILABLE",
        b"Block images: UNAVAILABLE",
        b"Skill commands:",
        b"Show hardware cursor:",
        b"Editor padding:",
        b"Output padding:",
        b"Autocomplete max items:",
        b"Clear on shrink:",
        b"Terminal progress:",
    ):
        if marker not in bytes(output):
            raise SystemExit(f"settings list is missing entry: {marker!r}")

    # Transport row (14 downs from Auto-compact): Enter cycles auto -> sse.
    downs(14)
    if b"Transport:" not in bytes(output):
        raise SystemExit("transport row did not scroll into view")
    if not key(b"\r", b"Transport: sse", timeout=4.0):
        raise SystemExit("transport did not cycle to sse")

    # Thinking row (11 more downs from Transport): the submenu still opens
    # from the list and applying a level returns to the settings list.
    downs(11)
    if not key(b"\r", b"Thinking Level", timeout=4.0):
        raise SystemExit("enter did not open the thinking submenu")
    if not key(b"\r", b"Thinking level:", timeout=4.0):
        raise SystemExit("selecting a level did not return to settings")

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

    # The transport change was persisted with the Pi key name.
    with open(os.path.join(agent, "settings.json")) as raw:
        settings = json.load(raw)
        if settings.get("transport") != "sse":
            raise SystemExit("saved settings do not carry transport sse")
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

echo "e2e: settings list order, value cycling, submenu and persistence work in a PTY"
