#!/bin/sh
set -eu

# PTY e2e for settings persistence and the /config resource selector:
# changing the theme in /settings survives a restart, and /config lists
# skills/prompts with enable toggles.
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
root = tempfile.mkdtemp(prefix="adou-tui-config-")
home = os.path.join(root, "home")
os.makedirs(home)
agent = os.path.join(root, "agent")
os.makedirs(agent)
open(os.path.join(agent, ".adou-setup"), "w").close()
# A project skill and prompt so the /config selector has entries.
os.makedirs(os.path.join(agent, "skills"))
os.makedirs(os.path.join(agent, "prompts"))
with open(os.path.join(agent, "skills", "demo.md"), "w") as out:
    out.write("---\nname: demo\ndescription: Demo skill\n---\n\nInstructions\n")
with open(os.path.join(agent, "prompts", "review.md"), "w") as out:
    out.write("---\ndescription: Review\n---\n\nReview $@\n")
env = os.environ.copy()
env.update(
    {
        "HOME": home,
        "PI_CODING_AGENT_DIR": agent,
        "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
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


def paste_text(text, until, timeout=4.0):
    os.write(fd, b"\x1b[200~")
    time.sleep(0.15)
    os.write(fd, text.encode())
    time.sleep(0.15)
    os.write(fd, b"\x1b[201~")
    return collect(until, timeout=timeout)


def quit_tui(fd, pid, status):
    os.write(fd, b"/quit\r")
    deadline = time.time() + 6.0
    while time.time() < deadline:
        waited, st = os.waitpid(pid, os.WNOHANG)
        if waited:
            return st
        time.sleep(0.1)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    return None


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    if not collect(b"\x1b[>1u", timeout=10.0):
        raise SystemExit("TUI did not become ready for keyboard input")

    # Change the theme in /settings; the selection is saved.
    if not key(b"/settings\r", b"Settings", timeout=5.0):
        raise SystemExit("/settings did not open")
    collect(timeout=0.3)
    # Move down to the Theme row (26 downs from Auto-compact) and open the
    # theme submenu.  Like Pi, the submenu pre-selects the current theme
    # (dark), so one down reaches light; Enter applies it and the choice is
    # saved to settings.json.
    for _ in range(26):
        os.write(fd, b"\x1b[B")
        time.sleep(0.12)
    collect(timeout=0.5)
    if not key(b"\r", b"Automatic", timeout=4.0):
        raise SystemExit("theme submenu did not open")
    os.write(fd, b"\x1b[B")
    time.sleep(0.12)
    # Enter on light applies and returns to the settings list (top viewport).
    if not key(b"\r", b"Auto-compact:", timeout=4.0):
        raise SystemExit("theme selection did not return to the settings list")
    for _ in range(26):
        os.write(fd, b"\x1b[B")
        time.sleep(0.12)
    collect(timeout=0.5)
    if b"Theme: light" not in bytes(output):
        raise SystemExit("theme row does not show the light variant")
    quit_tui(fd, pid, status)

    # Restart: the theme must be restored from settings.
    pid2, fd2 = spawn()
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

        def paste2(text, until, timeout=4.0):
            os.write(fd2, b"\x1b[200~")
            time.sleep(0.12)
            os.write(fd2, text.encode())
            time.sleep(0.12)
            os.write(fd2, b"\x1b[201~")
            return collect2(until, timeout=timeout)

        fcntl.ioctl(fd2, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        if not collect2(b"\x1b[>1u", timeout=10.0):
            raise SystemExit("restarted TUI did not become ready for keyboard input")
        # The /config selector lists the seeded skill and prompt.
        os.write(fd2, b"/config\r")
        if not collect2(b"Resources", timeout=5.0):
            raise SystemExit("/config did not open the resource selector")
        collect2(timeout=0.4)
        if b"demo" not in bytes(output2) or b"review" not in bytes(output2):
            raise SystemExit("/config resource list is missing entries")
        # Search and toggle an enabled skill.  The resource remains in the
        # selector after disabling, and its explicit empty allow-list survives
        # the save (so it can be enabled again).
        if not paste2("demo", b"demo: enabled", timeout=4.0):
            raise SystemExit("/config search did not find the skill")
        os.write(fd2, b" ")
        if not collect2(b"demo: disabled", timeout=4.0):
            raise SystemExit("/config toggle did not disable the searched skill")
        os.write(fd2, b"\x1b")
        time.sleep(0.25)
        os.write(fd2, b"\x1b")
        time.sleep(0.25)
        # Reopen and switch write scope; inherited resources remain visible
        # while the header changes to project-local mode.
        os.write(fd2, b"/config\r")
        if not collect2(b"Resources", timeout=5.0):
            raise SystemExit("/config did not reopen after cancel recovery")
        if not collect2(b"demo: disabled", timeout=4.0):
            raise SystemExit("disabled resource state did not persist in the selector")
        os.write(fd2, b"\t")
        if not collect2(b"project resources", timeout=4.0):
            raise SystemExit("Tab did not switch config scope")
        os.write(fd2, b"\x1b")
        # Drain the close frame before sending /quit.  Without this input
        # barrier, the ESC and slash command can arrive in one terminal read
        # batch and the slash text is still consumed by the config query.
        collect2(timeout=0.5)
        # Verify the persisted theme file.
        with open(os.path.join(agent, "settings.json")) as raw:
            settings = json.load(raw)
            if settings.get("theme") != "light":
                raise SystemExit("saved settings do not carry the light theme")
        result = quit_tui(fd2, pid2, status2)
        if result is None or os.waitstatus_to_exitcode(result) != 0:
            raise SystemExit("restarted TUI did not exit cleanly after config cancel")
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
            os.waitpid(pid, 0)
        except OSError:
            pass
    shutil.rmtree(root, ignore_errors=True)
PY

echo "e2e: settings persistence and resource config selector work in a PTY"
