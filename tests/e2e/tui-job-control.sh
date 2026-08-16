#!/bin/sh
set -eu

# RM-TUI-003 regression: Ctrl+Z on an idle TUI followed by `fg` from the
# shell must resume the TUI instead of killing it.  The interrupted read
# (EINTR) on SIGTSTP/SIGCONT must be retried, not treated as EOF.  The TUI
# runs as a foreground child of an interactive PTY shell (the shell is the
# session leader, Adou a non-orphan foreground process group), matching the
# real Herdr reproduction: Ctrl+Z -> shell prompt -> fg -> full repaint ->
# /quit exits 0.
#
# Every marker wait scans only the bytes appended since the step's start
# offset, so a stale prompt or ready sequence from an earlier step can never
# satisfy a later wait (and input is never sent into a still-running TUI
# because of a false positive).
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi
ADOU_PROCESS_GROUP_HELPER=${ADOU_PROCESS_GROUP_HELPER:-$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/adou-process-group}
if [ ! -x "$ADOU_PROCESS_GROUP_HELPER" ]; then
    echo "e2e: process group helper not found: $ADOU_PROCESS_GROUP_HELPER" >&2
    exit 2
fi

ADOU_BIN="$binary" ADOU_PROCESS_GROUP_HELPER="$ADOU_PROCESS_GROUP_HELPER" \
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" python3 - <<'PY'
import errno
import fcntl
import os
import pty
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
helper = os.environ["ADOU_PROCESS_GROUP_HELPER"]
script_dir = os.environ["SCRIPT_DIR"]

root = tempfile.mkdtemp(prefix="adou-job-control-")
home = os.path.join(root, "home")
agent = os.path.join(home, ".adou", "agent")
os.makedirs(agent)
open(os.path.join(agent, ".adou-setup"), "w").close()

env = os.environ.copy()
env.update(
    {
        "HOME": home,
        "PI_CODING_AGENT_DIR": agent,
        "ADOU_PROCESS_GROUP_HELPER": helper,
        "DEEPSEEK_API_KEY": "job-control-e2e-key",
        "ADOU_DEBUG": "1",
        "ADOU_DEBUG_FILE": os.path.join(root, "debug.log"),
    }
)

# The interactive shell is the session leader; Adou starts as its foreground
# child (a real process group, not an orphaned pty.fork exec).
shell_pid, fd = pty.fork()
if shell_pid == 0:
    os.chdir(root)
    os.execvpe("/bin/bash", ["/bin/bash", "--norc", "--noprofile", "-i"], env)
output = bytearray()

PROMPT = b"ADOU_PROMPT> "


def collect(start, timeout=10.0, until=None):
    # Scans output[start:] only; until=None just drains for `timeout`.
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


def send(data, start, until=None, timeout=10.0):
    os.write(fd, data)
    time.sleep(0.08)
    return collect(start, timeout=timeout, until=until)


def wait_exit(pid, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            waited, st = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return 0
        if waited:
            return os.waitstatus_to_exitcode(st)
        time.sleep(0.05)
    return None


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    start = len(output)
    collect(start, timeout=10.0)
    if len(output) <= start:
        raise SystemExit("interactive shell did not start")
    if not send(b"export PS1='ADOU_PROMPT> '\r", len(output), until=PROMPT, timeout=10.0):
        raise SystemExit("shell did not become interactive")

    # Launch Adou as a foreground child of the shell.
    command = (
        "cd %s && %s --approve --no-context-files --no-session "
        "--provider deepseek --model deepseek/deepseek-v4-flash --thinking off "
        "--base-url http://127.0.0.1:1 --max-tokens 128\r" % (root, binary)
    )
    if not send(command.encode(), len(output), until=b"\x1b[>1u", timeout=20.0):
        raise SystemExit("TUI did not become ready for keyboard input")

    # Idle TUI: Ctrl+Z must restore the terminal and give the shell the
    # prompt back.  The "Stopped" notice and the fresh PROMPT can arrive in
    # the same read burst, so both are asserted inside ONE wait over the
    # single step slice: waiting for Stopped first and then re-anchoring on
    # len(output) would miss a prompt that already landed.
    step_start = len(output)
    if not send(b"\x1a", step_start, until=PROMPT, timeout=10.0):
        raise SystemExit("shell prompt did not return after Ctrl+Z")
    if b"Stopped" not in bytes(output[step_start:]):
        raise SystemExit("Ctrl+Z did not report the stopped job")

    # fg resumes the stopped job; the TUI re-enters raw mode and must emit a
    # cleared full repaint (renderer.invalidate on reenter) in NEW bytes.
    if not send(b"fg\r", len(output), until=b"\x1b[2J", timeout=15.0):
        raise SystemExit("fg did not repaint the full TUI frame")

    # The resumed TUI must still process input and quit cleanly; the fresh
    # shell prompt proves Adou exited and was reaped, and $? proves status 0.
    if not send(b"/quit\r", len(output), until=PROMPT, timeout=15.0):
        raise SystemExit("TUI did not exit after /quit (fg did not resume it)")
    if not send(b"echo ADOU_EXIT_$?\r", len(output), until=b"ADOU_EXIT_0", timeout=10.0):
        raise SystemExit("Adou did not exit with status 0")

    text = bytes(output).decode("utf-8", "replace")
    if "terminal input failed" in text:
        raise SystemExit("interrupted read killed the input reader (RM-TUI-003)")
    try:
        debug_log = open(os.path.join(root, "debug.log")).read()
    except OSError:
        debug_log = ""
    if "terminal input failed" in debug_log:
        raise SystemExit("debug log shows terminal input failure")
    # "run loop end" after /quit is the normal shutdown marker; a premature
    # exit would have failed the fg repaint or the /quit interaction above.
    print("e2e: Ctrl+Z -> shell prompt -> fg -> full repaint -> /quit exit 0 OK")

    send(b"exit\r", len(output), timeout=5.0)
    shell_code = wait_exit(shell_pid, timeout=10.0)
    if shell_code is None:
        os.kill(shell_pid, signal.SIGKILL)
        raise SystemExit("interactive shell did not exit")
finally:
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.kill(shell_pid, signal.SIGKILL)
    except OSError:
        pass
    shutil.rmtree(root, ignore_errors=True)
PY
