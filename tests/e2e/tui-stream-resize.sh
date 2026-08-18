#!/bin/sh
set -eu

# Batch 6 combination regression: stream a local tool turn and its final
# answer while the PTY is resized repeatedly.  Toggle tool output expansion
# during the second stream, then open/close Settings after the stream settles.
# The assertions cover the render lock, SIGWINCH redraw path, terminal writes,
# and terminal restoration without contacting a real provider.
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
import fcntl
import json
import os
import pty
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

binary = os.environ["ADOU_BIN"]
helper = os.environ["ADOU_PROCESS_GROUP_HELPER"]


def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()


def stream_parts(turn, parts):
    chunks = []
    chunks.append(event({
        "id": "resize-%d" % turn,
        "object": "chat.completion.chunk",
        "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}],
    }))
    for index, part in enumerate(parts):
        chunks.append(event({
            "id": "resize-%d" % turn,
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {"content": part}}],
        }))
        if index != len(parts) - 1:
            chunks.append(b"__DELAY__")
    chunks.append(event({
        "id": "resize-%d" % turn,
        "object": "chat.completion.chunk",
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }))
    chunks.append(b"data: [DONE]\n\n")
    return chunks


def tool_parts():
    arguments = json.dumps({"command": "printf 'RESIZE_TOOL_OK\\n'"}, separators=(",", ":"))
    return [
        event({
            "id": "resize-1",
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {"role": "assistant", "content": "streaming "}}],
        }),
        event({
            "id": "resize-1",
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {"content": "before tool"}}],
        }),
        event({
            "id": "resize-1",
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {"tool_calls": [{
                "index": 0,
                "id": "resize-call-1",
                "type": "function",
                "function": {"name": "bash", "arguments": arguments},
            }]}}],
        }),
        event({
            "id": "resize-1",
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
        }),
        b"data: [DONE]\n\n",
    ]


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests = 0

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        Provider.requests += 1
        if Provider.requests == 1:
            parts = tool_parts()
        elif Provider.requests == 2:
            parts = stream_parts(2, [
                "RESIZE_",
                "STREAM_",
                "OK",
            ])
        else:
            self.send_response(500)
            self.send_header("Connection", "close")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        for part in parts:
            if part == b"__DELAY__":
                time.sleep(0.18)
                continue
            try:
                self.wfile.write(part)
                self.wfile.flush()
            except OSError:
                return


server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]

root = tempfile.mkdtemp(prefix="adou-tui-stream-resize-")
home = os.path.join(root, "home")
agent = os.path.join(home, ".adou", "agent")
os.makedirs(agent)
open(os.path.join(agent, ".adou-setup"), "w").close()

env = os.environ.copy()
env.update({
    "HOME": home,
    "PI_CODING_AGENT_DIR": agent,
    "ADOU_PROCESS_GROUP_HELPER": helper,
    "DEEPSEEK_API_KEY": "stream-resize-e2e-key",
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


def collect(fd, output, pid, until=None, timeout=15.0):
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


def resize(fd, rows, columns):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
    time.sleep(0.08)


pid = 0
fd = 0
output = bytearray()
try:
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(root)
        os.execvpe(binary, args, env)

    resize(fd, 24, 100)
    if not collect(fd, output, pid, b"\x1b[>1u", timeout=15.0):
        raise SystemExit("TUI did not become ready for keyboard input")

    os.write(fd, b"run resize\r")
    if not collect(fd, output, pid, b"before tool", timeout=15.0):
        raise SystemExit("first streaming delta did not render")
    resize(fd, 24, 80)
    resize(fd, 12, 52)
    resize(fd, 30, 120)

    if not collect(fd, output, pid, b"RESIZE_TOOL_OK", timeout=20.0):
        raise SystemExit("streaming bash tool result did not render")
    # Ctrl+O is allowed while streaming and forces a redraw over the current
    # tool result while the second provider request is still active.
    os.write(fd, b"\x0f")
    resize(fd, 18, 64)
    resize(fd, 24, 100)
    if not collect(fd, output, pid, b"RESIZE_STREAM_OK", timeout=20.0):
        raise SystemExit("final streaming answer did not render")
    # Let the session stream publish its terminal event and return the main
    # loop to idle before entering a slash command.
    collect(fd, output, pid, timeout=0.8)

    # Exercise a real overlay after stream completion while a SIGWINCH redraw
    # is pending; Esc must return to the editor without killing the session.
    os.write(fd, b"/settings\r")
    if not collect(fd, output, pid, b"Settings", timeout=10.0):
        raise SystemExit("settings overlay did not open after streaming")
    resize(fd, 16, 58)
    os.write(fd, b"\x1b")
    time.sleep(0.2)
    os.write(fd, b"/quit\r")
    collect(fd, output, pid, timeout=8.0)

    # Drain until the child exits so the restore sequence is included in the
    # assertions below.
    deadline = time.time() + 10.0
    status = None
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
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SystemExit("raw terminal stream is not valid UTF-8: %s" % exc)
    if "bad address" in text or "Render failed" in text or "terminal input failed" in text:
        raise SystemExit("stream/resize run surfaced a terminal or render failure")
    if text.count("\x1b[?2026h") != text.count("\x1b[?2026l"):
        raise SystemExit("stream/resize run left sync output unbalanced")
    if not raw.endswith(b"\x1b[<u\x1b[?2004l\x1b[?25h"):
        raise SystemExit("terminal restore was not the final output")
    if Provider.requests != 2:
        raise SystemExit("expected two provider requests, got %d" % Provider.requests)
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
    server.shutdown()
    shutil.rmtree(root, ignore_errors=True)

print("e2e: streaming tool/final answer survive PTY resize, overlay redraw and clean restore")
PY
