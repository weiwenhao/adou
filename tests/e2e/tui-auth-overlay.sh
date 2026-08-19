#!/bin/sh
set -eu

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
root = tempfile.mkdtemp(prefix="adou-tui-auth-")
env = os.environ.copy()
env.update(
    {
        "ADOU_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
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

def paste_text(text, until, timeout=4.0):
    os.write(fd, b"\x1b[200~")
    time.sleep(0.12)
    os.write(fd, text.encode())
    time.sleep(0.12)
    os.write(fd, b"\x1b[201~")
    return collect(until, timeout=timeout)

try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 160, 0, 0))
    if not collect(b"\x1b[>1u", timeout=10.0):
        raise SystemExit("TUI did not become ready for keyboard input")
    os.write(fd, b"/login\r")
    if not collect(b"Select authentication method:"):
        raise SystemExit("/login did not open the authentication selector")
    # The title and lower border can arrive in separate PTY reads even though
    # they belong to the same synchronized render frame.
    collect(timeout=0.5)
    if b"\x1b[38;2;138;190;183mSelect authentication method:" not in output:
        raise SystemExit("authentication selector title is not Pi accent colored")
    if b"\xe2\x86\x92" not in output or b"Sign in with an account" not in output:
        raise SystemExit("authentication selector account option is missing")
    if b"Sign in with an API key" not in output:
        raise SystemExit("authentication selector API-key option is missing")
    if output.count(b"\x1b[38;2;95;135;255m") < 2:
        raise SystemExit("authentication selector does not render Pi border colors")

    # Choose the API-key path, search the runtime provider registry, and verify
    # an empty key reports an error without wedging the overlay.  Escape then
    # recovers cleanly from the error state.
    os.write(fd, b"\x1b[B")
    time.sleep(0.1)
    os.write(fd, b"\r")
    if not collect(b"Select provider:", timeout=4.0):
        raise SystemExit("API-key method did not open the provider selector")
    if not paste_text("deepseek", b"DeepSeek", timeout=4.0):
        raise SystemExit("runtime provider selector search did not find DeepSeek")
    time.sleep(0.5)
    collect(timeout=0.5)
    os.write(fd, b"\r")
    if not collect(b"Login to deepseek", timeout=4.0):
        raise SystemExit("provider selection did not open the API-key field")
    os.write(fd, b"\r")
    if not collect(b"API key is required", timeout=4.0):
        raise SystemExit("empty API-key submission did not render recoverable error")
    os.write(fd, b"\x1b")
    time.sleep(0.2)
    # A fresh /login confirms the cancelled error overlay is gone.
    os.write(fd, b"/login\r")
    if not collect(b"Select authentication method:", timeout=4.0):
        raise SystemExit("cancelled API-key overlay did not restore the editor")
    # Escape cancels the selector; then quit through the normal slash command
    # path so terminal restoration is exercised instead of killing the child.
    os.write(fd, b"\x1b")
    time.sleep(0.15)
    os.write(fd, b"/quit\r")
    collect(timeout=3.0)
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
            os.waitpid(pid, 0)
        except (ChildProcessError, ProcessLookupError):
            pass
    shutil.rmtree(root, ignore_errors=True)

print("e2e: Pi-compatible TUI authentication overlay and terminal exit OK")
PY
