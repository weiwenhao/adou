#!/bin/sh
set -eu

# RM-TUI-001/002 regression: drive the real TUI through streaming partial
# tool result -> tool complete -> final assistant -> idle with a local
# fixture that emits deltas back-to-back, then validate the raw terminal
# byte stream.  Every frame must be strict UTF-8 (no binary/memory bytes),
# the sync sequences must balance, and neither "bad address" nor
# "Render failed" may appear.  No real provider is involved.
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
import json
import os
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time

binary = os.environ["ADOU_BIN"]
helper = os.environ["ADOU_PROCESS_GROUP_HELPER"]
script_dir = os.environ["SCRIPT_DIR"]

probe = socket.socket()
probe.bind(("127.0.0.1", 0))
port = probe.getsockname()[1]
probe.close()

root = tempfile.mkdtemp(prefix="adou-redraw-storm-")
home = os.path.join(root, "home")
agent = os.path.join(home, ".adou", "agent")
req_dir = os.path.join(root, "reqs")
os.makedirs(agent)
os.makedirs(req_dir)
open(os.path.join(agent, ".adou-setup"), "w").close()

server_log = os.path.join(root, "server.log")
server = subprocess.Popen(
    [sys.executable, os.path.join(script_dir, "tui-redraw-storm-fixture.py"), str(port), req_dir],
    stdout=open(server_log, "w"),
    stderr=subprocess.STDOUT,
)
time.sleep(0.8)
if server.poll() is not None:
    raise SystemExit(f"fixture server failed to start: {open(server_log).read()}")

env = os.environ.copy()
env.update(
    {
        "HOME": home,
        "PI_CODING_AGENT_DIR": agent,
        "ADOU_PROCESS_GROUP_HELPER": helper,
        "DEEPSEEK_API_KEY": "redraw-storm-e2e-key",
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
    "--base-url",
    f"http://127.0.0.1:{port}",
    "--max-tokens",
    "128",
]


def launch(extra):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(root)
        os.execvpe(binary, base_args + extra, env)
    return pid, fd


reaped = {}


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
        if pid not in reaped:
            try:
                waited, child_status = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                reaped[pid] = None
                break
            if waited:
                reaped[pid] = child_status
                break
    return until is not None and until in output


def send(fd, output, pid, data, until=None, timeout=15.0):
    os.write(fd, data)
    time.sleep(0.08)
    return collect(fd, output, pid, until=until, timeout=timeout)


def quit_tui(fd, output, pid):
    send(fd, output, pid, b"/quit\r", timeout=10.0)
    deadline = time.time() + 10.0
    while time.time() < deadline:
        if pid in reaped:
            child_status = reaped[pid]
            if child_status is not None and os.waitstatus_to_exitcode(child_status) != 0:
                raise SystemExit(f"TUI exited with status {os.waitstatus_to_exitcode(child_status)}")
            return
        time.sleep(0.05)
    os.kill(pid, signal.SIGKILL)
    raise SystemExit("TUI did not exit after /quit")


def strict_utf8_ok(data):
    try:
        data.decode("utf-8", errors="strict")
        return True
    except UnicodeDecodeError:
        return False


pid = 0
fd = 0
try:
    pid, fd = launch([])
    output = bytearray()
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    if not collect(fd, output, pid, b"\x1b[>1u", timeout=15.0):
        raise SystemExit("TUI did not become ready for keyboard input")
    # Submit the prompt; the fixture then streams text + bash tool call, the
    # real bash tool runs locally, and the second fixture stream delivers the
    # final answer.  Wait for the rendered final marker, then a short settle
    # window so the deferred redraw drains to idle.
    if not send(fd, output, pid, b"run the check\r", b"MASTER_TLS_TOOL_OK", timeout=30.0):
        raise SystemExit("final assistant text never rendered")
    time.sleep(0.5)
    collect(fd, output, pid, timeout=1.0)

    raw = bytes(output)
    if not strict_utf8_ok(raw):
        bad = raw.decode("utf-8", errors="replace")
        print("e2e: raw terminal stream is not valid UTF-8")
        print(bad[-2000:])
        raise SystemExit(1)
    text = raw.decode("utf-8")
    if "\x00" in text:
        raise SystemExit("e2e: raw terminal stream carries NUL bytes")
    if "bad address" in text:
        raise SystemExit("e2e: 'bad address in system call argument' surfaced")
    if "Render failed" in text:
        raise SystemExit("e2e: 'Render failed' surfaced")
    sync_on = text.count("\x1b[?2026h")
    sync_off = text.count("\x1b[?2026l")
    if sync_on != sync_off:
        raise SystemExit(f"e2e: unbalanced sync sequences h={sync_on} l={sync_off}")
    reqs = sorted(os.listdir(req_dir))
    if len(reqs) != 2:
        raise SystemExit(f"e2e: expected 2 provider requests, got {reqs!r}")
    with open(os.path.join(req_dir, reqs[-1]), encoding="utf-8") as fh:
        final_payload = json.load(fh)
    # The second request carries the locally executed bash tool result back to
    # the provider; its presence proves the real bash tool ran end-to-end.
    if "REDRAW_TOOL_OK" not in json.dumps(final_payload, separators=(",", ":")):
        raise SystemExit("e2e: bash tool result missing from the second request stream")
    quit_tui(fd, output, pid)
finally:
    try:
        if fd:
            os.close(fd)
    except OSError:
        pass
    try:
        if pid:
            os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    server.terminate()
    try:
        server.wait(timeout=3)
    except subprocess.TimeoutExpired:
        server.kill()
    shutil.rmtree(root, ignore_errors=True)

print("e2e: redraw storm frames are valid UTF-8, balanced sync, no bad address")
PY
