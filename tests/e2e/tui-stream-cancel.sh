#!/bin/sh
set -eu

# TUI cancellation regression: after Ctrl+C wins a live provider turn, a
# provider that races one last normal SSE burst must not append that burst to
# the transcript.  The fixture deliberately sends a marker only after the
# PTY has requested cancellation.
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
python3 - <<'PY'
import errno
import json
import os
import pty
import select
import shutil
import signal
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

binary = os.environ["ADOU_BIN"]
helper = os.environ["ADOU_PROCESS_GROUP_HELPER"]


def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests = 0
    first_delta = threading.Event()
    release = threading.Event()

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        Provider.requests += 1
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        prefix = event({
            "id": "cancel-1",
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}],
        })
        first = event({
            "id": "cancel-1",
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {"content": "CANCEL_BEFORE_ABORT"}}],
        })
        self.wfile.write(prefix)
        self.wfile.write(first)
        self.wfile.flush()
        Provider.first_delta.set()
        Provider.release.wait(5)

        # A large burst makes the race observable even when the HTTP client
        # has already read ahead into its socket buffer.
        late = event({
            "id": "cancel-1",
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {"content": "CANCEL_AFTER_ABORT"}}],
        })
        try:
            for _ in range(64):
                self.wfile.write(late)
            self.wfile.write(event({
                "id": "cancel-1",
                "object": "chat.completion.chunk",
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            }))
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except OSError:
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]

root = tempfile.mkdtemp(prefix="adou-tui-stream-cancel-")
home = os.path.join(root, "home")
agent = os.path.join(home, ".adou", "agent")
os.makedirs(agent)
open(os.path.join(agent, ".adou-setup"), "w").close()

env = os.environ.copy()
env.update({
    "HOME": home,
    "ADOU_CODING_AGENT_DIR": agent,
    "ADOU_PROCESS_GROUP_HELPER": helper,
    "DEEPSEEK_API_KEY": "stream-cancel-e2e-key",
})
args = [
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
    "--base-url",
    "http://127.0.0.1:%d" % port,
    "--max-tokens",
    "128",
]


def collect(fd, output, until=None, timeout=15.0):
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
    return until is not None and until in output


pid = 0
fd = 0
output = bytearray()
status = None
try:
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(root)
        os.execvpe(binary, args, env)

    if not collect(fd, output, b"\x1b[>1u", timeout=15.0):
        raise SystemExit("TUI did not become ready for keyboard input")
    os.write(fd, b"cancel race\r")
    if not Provider.first_delta.wait(5):
        raise SystemExit("provider did not receive the cancellation fixture request")
    if not collect(fd, output, b"CANCEL_BEFORE_ABORT", timeout=15.0):
        raise SystemExit("first streaming delta did not render")

    os.write(fd, b"\x03")
    # Give the input coroutine a scheduling turn to call stream.abort(), then
    # release the provider's deliberately late normal frames.
    time.sleep(0.15)
    Provider.release.set()
    if not collect(fd, output, b"Operation aborted", timeout=15.0):
        # The status text is terminal-theme dependent; completion is still
        # validated by the clean /quit path and the absence of late output.
        collect(fd, output, timeout=1.0)

    os.write(fd, b"/quit\r")
    deadline = time.time() + 12.0
    while time.time() < deadline:
        try:
            waited, child_status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if waited:
            status = child_status
            break
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                output.extend(os.read(fd, 65536))
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
    code = os.waitstatus_to_exitcode(status)
    if code != 0:
        raise SystemExit("TUI exited with status %d" % code)

    raw = bytes(output)
    text = raw.decode("utf-8")
    if "CANCEL_AFTER_ABORT" in text:
        raise SystemExit("late provider output rendered after Ctrl+C cancellation")
    if "bad address" in text or "Render failed" in text or "terminal input failed" in text:
        raise SystemExit("cancel run surfaced a terminal or render failure")
    if not raw.endswith(b"\x1b[<u\x1b[?2004l\x1b[?25h"):
        raise SystemExit("terminal restore was not the final output")
    if Provider.requests != 1:
        raise SystemExit("expected one provider request, got %d" % Provider.requests)
finally:
    if fd:
        try:
            os.close(fd)
        except OSError:
            pass
    if pid:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        if status is None:
            try:
                os.waitpid(pid, 0)
            except OSError:
                pass
    Provider.release.set()
    server.shutdown()
    shutil.rmtree(root, ignore_errors=True)

print("e2e: TUI Ctrl+C suppresses late streaming output and restores the terminal")
PY
