#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

ADOU_BIN="$binary" python3 - <<'PY'
import base64
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
root = tempfile.mkdtemp(prefix="adou-tui-images-")
png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="


def seed(path):
    entries = [
        {"type":"session","version":3,"id":"image-session","timestamp":"2026-01-01T00:00:00.000Z","cwd":root},
        {"type":"message","id":"u1","parentId":None,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"inspect image","timestamp":1}},
        {"type":"message","id":"t1","parentId":"u1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"toolResult","toolCallId":"call-1","toolName":"read","content":[{"type":"text","text":"Image Size: 1x1."}],"images":[{"mimeType":"image/png","data":png}],"isError":False,"timestamp":2}},
        {"type":"message","id":"a1","parentId":"t1","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"IMAGE_UI_READY"}],"api":"openai-completions","provider":"deepseek","model":"deepseek-v4-flash","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":3}},
    ]
    with open(path, "w", encoding="utf-8") as out:
        for entry in entries:
            out.write(json.dumps(entry, separators=(",", ":")) + "\n")


def run_case(name, terminal_env, expected):
    case = os.path.join(root, name)
    os.makedirs(case)
    session = os.path.join(case, "session.jsonl")
    seed(session)
    agent = os.path.join(case, "agent")
    os.makedirs(agent)
    open(os.path.join(agent, ".adou-setup"), "w").close()
    write_log = os.path.join(case, "tui.log")
    env = os.environ.copy()
    for key in (
        "TERM_PROGRAM", "KITTY_WINDOW_ID", "ITERM_SESSION_ID", "TMUX",
        "TERMINAL_EMULATOR", "GHOSTTY_RESOURCES_DIR", "WEZTERM_PANE",
        "WARP_SESSION_ID", "WARP_TERMINAL_SESSION_UUID", "WT_SESSION",
    ):
        env.pop(key, None)
    env.update({
        "ADOU_CODING_AGENT_DIR": agent,
        "ADOU_TUI_WRITE_LOG": write_log,
        "TERM": "xterm-256color",
        **terminal_env,
    })
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(binary, [binary, "--offline", "--no-context-files", "--session", session, "--provider", "deepseek", "--model", "deepseek-v4-flash"], env)

    output = bytearray()
    status = None
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 20, 80, 0, 0))
        deadline = time.time() + 10
        while time.time() < deadline and b"IMAGE_UI_READY" not in output:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    output.extend(os.read(fd, 65536))
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
        if b"IMAGE_UI_READY" not in output:
            raise SystemExit(f"{name}: restored transcript did not render")

        # Resize forces a second complete layout and verifies image rows do not
        # corrupt cursor accounting when the viewport width changes.
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 28, 112, 0, 0))
        time.sleep(0.25)
        os.write(fd, b"/quit\r")
        deadline = time.time() + 8
        while time.time() < deadline:
            waited, child_status = os.waitpid(pid, os.WNOHANG)
            if waited:
                status = child_status
                break
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    output.extend(os.read(fd, 65536))
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
        if status is None:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)
            raise SystemExit(f"{name}: TUI did not exit")
        if os.waitstatus_to_exitcode(status) != 0:
            raise SystemExit(f"{name}: TUI exited nonzero")
        raw = open(write_log, "rb").read()
        if expected not in raw:
            raise SystemExit(f"{name}: expected image protocol or fallback missing")
        if b"IMAGE_UI_READY" not in raw:
            raise SystemExit(f"{name}: assistant text disappeared around image rows")
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


try:
    run_case("kitty", {"TERM_PROGRAM":"kitty", "KITTY_WINDOW_ID":"1"}, b"\x1b_G")
    run_case("iterm2", {"TERM_PROGRAM":"iTerm.app", "ITERM_SESSION_ID":"test"}, b"\x1b]1337;File=")
    run_case("plain", {}, b"[Image: [image/png] 1x1]")
finally:
    if os.environ.get("ADOU_TUI_IMAGES_KEEP") != "1":
        shutil.rmtree(root, ignore_errors=True)
    else:
        print("kept image UI evidence at " + root)

print("e2e: Kitty, iTerm2, and plain-terminal image UI survive resize and restore OK")
PY
