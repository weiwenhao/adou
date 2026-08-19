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
root = tempfile.mkdtemp(prefix="adou-long-session-")
agent = os.path.join(root, "agent")
os.makedirs(agent)
open(os.path.join(agent, ".adou-setup"), "w").close()
session = os.path.join(root, "session.jsonl")
write_log = os.path.join(root, "tui.log")

parent = None
entries = [{"type":"session","version":3,"id":"long-session","timestamp":"2026-01-01T00:00:00.000Z","cwd":root}]
for index in range(160):
    user_id = f"u-{index}"
    assistant_id = f"a-{index}"
    entries.append({"type":"message","id":user_id,"parentId":parent,"timestamp":f"2026-01-01T00:{index // 60:02d}:{index % 60:02d}.000Z","message":{"role":"user","content":f"LONG_SESSION_USER_{index}","timestamp":index * 2 + 1}})
    entries.append({"type":"message","id":assistant_id,"parentId":user_id,"timestamp":f"2026-01-01T00:{index // 60:02d}:{index % 60:02d}.500Z","message":{"role":"assistant","content":[{"type":"text","text":f"LONG_SESSION_FINAL_{index}"}],"api":"openai-completions","provider":"deepseek","model":"deepseek-v4-flash","stopReason":"stop","timestamp":index * 2 + 2}})
    parent = assistant_id
with open(session, "w", encoding="utf-8") as output:
    for entry in entries:
        output.write(json.dumps(entry, separators=(",", ":")) + "\n")

env = os.environ.copy()
env.update({"ADOU_CODING_AGENT_DIR":agent, "ADOU_TUI_WRITE_LOG":write_log, "TERM":"xterm-256color"})
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(binary, [binary, "--offline", "--no-context-files", "--session", session, "--provider", "deepseek", "--model", "deepseek-v4-flash"], env)

status = None
output = bytearray()
try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    deadline = time.time() + 15
    while time.time() < deadline and b"LONG_SESSION_FINAL_159" not in output:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                output.extend(os.read(fd, 65536))
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
    if b"LONG_SESSION_FINAL_159" not in output:
        raise SystemExit("long session tail did not render")
    for index in range(20):
        rows, columns = ((20, 76) if index % 2 == 0 else (42, 156))
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        time.sleep(0.03)
        ready, _, _ = select.select([fd], [], [], 0)
        if ready:
            try:
                os.read(fd, 65536)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
    time.sleep(0.3)
    os.write(fd, b"/quit\r")
    deadline = time.time() + 10
    while time.time() < deadline:
        waited, child_status = os.waitpid(pid, os.WNOHANG)
        if waited:
            status = child_status
            break
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                os.read(fd, 65536)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
        time.sleep(0.05)
    if status is None:
        raise SystemExit("long session TUI did not exit")
    if os.waitstatus_to_exitcode(status) != 0:
        raise SystemExit("long session TUI exited nonzero")
    rendered = open(write_log, "rb").read()
    if b"LONG_SESSION_FINAL_159" not in rendered:
        raise SystemExit("long session write log lost the active tail")
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

print("e2e: 320-message TUI history survives repeated resize and clean exit")
PY
