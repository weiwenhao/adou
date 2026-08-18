#!/bin/sh
set -eu

# Pi parity regression for lifecycle debug routing: Pi has no --debug in the
# TUI (the /debug command writes a file); Adou's --debug must therefore keep
# the interactive terminal byte stream clean (ADOU_DEBUG_FILE only), while
# headless modes keep the historical stderr stream.  Both branches go
# through the real application entry path.
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

ADOU_BIN="$binary" SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" python3 - <<'PY'
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

root = tempfile.mkdtemp(prefix="adou-debug-iso-")
home = os.path.join(root, "home")
agent = os.path.join(home, ".adou", "agent")
debug_file = os.path.join(root, "debug.log")
os.makedirs(agent)
open(os.path.join(agent, ".adou-setup"), "w").close()

env = os.environ.copy()
env.update(
    {
        "HOME": home,
        "PI_CODING_AGENT_DIR": agent,
        "ADOU_DEBUG": "1",
        "ADOU_DEBUG_FILE": debug_file,
        "DEEPSEEK_API_KEY": "debug-isolation-e2e-key",
    }
)

base_args = [
    binary,
    "--approve",
    "--no-context-files",
    "--no-session",
    "--provider",
    "deepseek",
    "--model",
    "deepseek/deepseek-v4-flash",
    "--thinking",
    "off",
    "--max-tokens",
    "128",
]


def wait_exit(pid, fd, output, timeout=10.0):
    # Drain the pty while waiting so a momentarily full output queue can
    # never stall the child's exit path.
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            waited, st = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return 0
        if waited:
            return os.waitstatus_to_exitcode(st)
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                output.extend(os.read(fd, 65536))
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
        time.sleep(0.05)
    return None


try:
    # Part A: interactive TUI.  Raw PTY bytes must never carry a debug line,
    # while ADOU_DEBUG_FILE receives them.
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(root)
        os.execvpe(binary, base_args, env)
    output = bytearray()
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        deadline = time.time() + 15.0
        ready = False
        while time.time() < deadline:
            if b"\x1b[>1u" in output:
                ready = True
                break
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    output.extend(os.read(fd, 65536))
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
        if not ready and b"\x1b[>1u" not in output:
            raise SystemExit("TUI did not become ready")
        time.sleep(0.5)
        deadline = time.time() + 2.0
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    output.extend(os.read(fd, 65536))
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
        raw = bytes(output)
        if b"[adou debug]" in raw:
            raise SystemExit("interactive TUI byte stream carries debug lines")
        os.write(fd, b"/quit\r")
        code = wait_exit(pid, fd, output, timeout=10.0)
        if code != 0:
            raise SystemExit(f"TUI exited with status {code}")
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    with open(debug_file, encoding="utf-8", errors="replace") as fh:
        debug_text = fh.read()
    if "[adou debug]" not in debug_text or "run loop start" not in debug_text:
        raise SystemExit("ADOU_DEBUG_FILE missing lifecycle lines in TUI mode")
    if "config: resolve complete" not in debug_text or ("models: remote catalog refresh skipped" not in debug_text and "models: startup catalog refresh skipped" not in debug_text):
        raise SystemExit("ADOU_DEBUG_FILE missing model startup diagnostics in TUI mode")
    print("e2e: TUI mode keeps the terminal clean and logs to ADOU_DEBUG_FILE")

    # Part B: headless mode keeps the historical stderr stream.  Offline
    # makes the run deterministic (no provider network).
    os.remove(debug_file)
    proc = subprocess.run(
        base_args + ["--offline", "-p", "hi"],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if proc.returncode != 0:
        raise SystemExit(f"headless run exited with status {proc.returncode}")
    if "[adou debug]" not in proc.stderr:
        raise SystemExit("headless mode lost the stderr debug stream")
    with open(debug_file, encoding="utf-8", errors="replace") as fh:
        debug_text = fh.read()
    if "[adou debug]" not in debug_text:
        raise SystemExit("headless mode did not write ADOU_DEBUG_FILE")
    if "config: resolve complete" not in debug_text or "models: startup catalog refresh skipped" not in debug_text:
        raise SystemExit("headless mode missing model startup diagnostics")
    print("e2e: headless mode keeps stderr debug and the debug file")
finally:
    shutil.rmtree(root, ignore_errors=True)
PY
