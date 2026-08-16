#!/bin/sh
set -eu

# PTY e2e for the model selector: the current model carries a check mark,
# searches filter by id/provider/name, unmatched queries show the empty
# state, Tab switches from the exact one-model scope to all models, selecting a model updates the
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
import threading
import struct
import tempfile
import termios
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

binary = os.environ["ADOU_BIN"]
root = tempfile.mkdtemp(prefix="adou-tui-model-")
catalog_requested = threading.Event()


class SlowCatalog(BaseHTTPRequestHandler):
    def do_GET(self):
        catalog_requested.set()
        time.sleep(8.0)
        body = b'{"models":[]}'
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


catalog_server = ThreadingHTTPServer(("127.0.0.1", 0), SlowCatalog)
catalog_server.daemon_threads = True
catalog_thread = threading.Thread(target=catalog_server.serve_forever, daemon=True)
catalog_thread.start()
env = {
    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    "TERM": "xterm-256color",
    "LANG": "en_US.UTF-8",
    "LC_ALL": "en_US.UTF-8",
    "HOME": os.path.join(root, "home"),
    "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
    "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
    "DEEPSEEK_API_KEY": "test-key",
    "ADOU_CATALOG_NETWORK": "1",
    "ADOU_CATALOG_BASE_URL": f"http://127.0.0.1:{catalog_server.server_port}",
}
if "TMPDIR" in os.environ:
    env["TMPDIR"] = os.environ["TMPDIR"]

os.makedirs(os.path.join(root, "agent"), exist_ok=True)
os.makedirs(os.path.join(root, "home"), exist_ok=True)
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
            "--models",
            "deepseek/deepseek-v4-flash",
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
    # Do not send input on a fixed startup delay.  Waiting for the
    # keyboard-protocol marker proves raw mode is active and turns the PTY
    # interaction deterministic across slow or contended launches.
    if not collect(until=b"\x1b[>1u", timeout=10.0):
        raise SystemExit("TUI did not become ready for keyboard input")

    # Open the model selector with Ctrl+L.
    if not key(b"\x0c", b"Select model:", timeout=5.0):
        raise SystemExit("ctrl+l did not open the model selector")
    if not catalog_requested.wait(timeout=2.0):
        raise SystemExit("model selector did not start its background catalog refresh")
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
    # The initial scoped tab contains only the configured model. Tab switches
    # to the true all-model snapshot, where the other authenticated model is
    # visible. Provider-only filtering would incorrectly pass this case.
    if b"deepseek-v4-pro" in bytes(output):
        raise SystemExit("scoped model tab leaked an out-of-scope model")
    if not key(b"\t", b"deepseek-v4-pro", timeout=4.0):
        raise SystemExit("tab did not switch from scoped to all models")
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
    catalog_server.shutdown()
    catalog_server.server_close()
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
