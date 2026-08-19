#!/bin/sh
set -eu

# PTY e2e for the skills lifecycle: start with no skills, create a valid
# SKILL.md, /reload re-discovers it (completion + /skill list + system prompt
# + /skill:name expansion), and --no-skills disables all of it.
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi
# The fixture process chdirs into a temporary project before exec. Resolve an
# environment-supplied relative path while it still refers to the repo cwd.
case "$binary" in
    /*) ;;
    *) binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary") ;;
esac
ADOU_BIN="$binary" SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" python3 - <<'PY'
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
script_dir = os.environ["SCRIPT_DIR"]
port_env = os.environ.get("ADOU_E2E_SKILLS_RELOAD_PORT")
if port_env:
    port = int(port_env)
else:
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()

root = tempfile.mkdtemp(prefix="adou-skills-reload-")
# Every child runs chdir'd into the fixture project with HOME, the agent
# directory (sessions, trust store, settings) fully isolated so neither a
# real ~/.agents/skills nor a real ~/.adou/agent can leak into the fixture
# assertions.
home = os.path.join(root, "home")
agent = os.path.join(home, ".adou", "agent")
os.makedirs(agent)
open(os.path.join(agent, ".adou-setup"), "w").close()
os.makedirs(os.path.join(root, "project", ".git"))

server_log = os.path.join(root, "server.log")
server = subprocess.Popen(
    [sys.executable, os.path.join(script_dir, "skills-fixture-server.py"), str(port)],
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
        "ADOU_CODING_AGENT_DIR": agent,
        "DEEPSEEK_API_KEY": "skills-reload-e2e-key",
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
    "deepseek-v4-flash",
    "--base-url",
    f"http://127.0.0.1:{port}",
    "--max-tokens",
    "128",
]


def launch(extra):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(project)
        os.execvpe(binary, base_args + extra, env)
    return pid, fd


# Reaped exit statuses per pid: collect() waits non-blocking and would
# otherwise steal the child from quit_tui's own waitpid, so the first reaper
# records the status here and every later check reads it back.
reaped = {}


def server_bodies():
    try:
        with open(server_log) as fh:
            return [line for line in fh.read().splitlines() if line.strip()]
    except OSError:
        return []


def collect(fd, output, status, pid, until=None, timeout=6.0):
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


def send(fd, output, status, pid, data, until=None, timeout=6.0):
    os.write(fd, data)
    time.sleep(0.08)
    return collect(fd, output, status, pid, until=until, timeout=timeout)


def quit_tui(fd, output, status, pid):
    send(fd, output, status, pid, b"/quit\r", timeout=6.0)
    deadline = time.time() + 6.0
    while time.time() < deadline:
        if pid in reaped:
            child_status = reaped[pid]
            if child_status is not None and os.waitstatus_to_exitcode(child_status) != 0:
                raise SystemExit(f"TUI exited with status {os.waitstatus_to_exitcode(child_status)}")
            return
        time.sleep(0.05)
    os.kill(pid, signal.SIGKILL)
    try:
        _, child_status = os.waitpid(pid, 0)
    except ChildProcessError:
        if pid in reaped:
            child_status = reaped[pid]
        else:
            raise SystemExit("TUI did not exit after /quit")
    raise SystemExit(f"TUI did not exit after /quit (status {os.waitstatus_to_exitcode(child_status)})")


def close(fd, pid):
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass


try:
    project = os.path.join(root, "project")

    # Phase A: no skills present; the /skill list is empty and no skill
    # expansion can happen.
    pid, fd = launch([])
    output = bytearray()
    status = None
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        if not collect(fd, output, status, pid, b"\x1b[>1u", timeout=10.0):
            raise SystemExit("TUI did not become ready for keyboard input")
        if not send(fd, output, status, pid, b"/skill\r", b"No skills found in user or project skills directories", timeout=5.0):
            raise SystemExit("fresh session did not report an empty skills list")
        if not send(fd, output, status, pid, b"/skill:demo hi\r", b"Unknown command", timeout=5.0):
            raise SystemExit("unknown /skill:demo was not rejected without the skill")
        if server_bodies():
            raise SystemExit("no provider round-trip should happen before a skill exists")
        quit_tui(fd, output, status, pid)
    finally:
        close(fd, pid)

    # Phase B: create a valid skill, /reload, then verify discovery, the
    # completion entry, the injected system prompt and the expansion.
    skill_dir = os.path.join(project, ".pi", "skills", "demo")
    os.makedirs(skill_dir)
    with open(os.path.join(skill_dir, "SKILL.md"), "w") as fh:
        fh.write(
            "---\n"
            "name: demo\n"
            "description: A demo skill injected into the system prompt\n"
            "---\n"
            "Instructions for the demo skill.\n"
        )

    pid, fd = launch([])
    output = bytearray()
    status = None
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        if not collect(fd, output, status, pid, b"\x1b[>1u", timeout=10.0):
            raise SystemExit("TUI did not become ready for keyboard input")
        if not send(fd, output, status, pid, b"/reload\r", b"Project instructions reloaded", timeout=5.0):
            raise SystemExit("/reload did not report the reload status")
        output.clear()
        # The live command menu completes "/skill" to "/skill:demo" on Enter,
        # so a trailing space first closes the menu; the submitted "/skill "
        # then runs the list command.
        os.write(fd, b"/skill ")
        time.sleep(0.15)
        if not send(fd, output, status, pid, b"\r", b"demo - A demo skill injected into the system prompt", timeout=5.0):
            raise SystemExit("/skill list does not show the reloaded demo skill")
        # Tab completion offers /skill:demo after the reload.  The output
        # buffer is fresh, so the completion must come from the new input
        # line: the echoed prefix plus the completed command.  ESC first
        # closes the /skill list overlay so the editor accepts input again.
        output.clear()
        send(fd, output, status, pid, b"\x1b", timeout=0.5)
        os.write(fd, b"/skill")
        time.sleep(0.15)
        collect(fd, output, status, pid, timeout=0.3)
        output.clear()
        if not send(fd, output, status, pid, b"\t", b"skill:demo", timeout=5.0):
            raise SystemExit("completion does not offer /skill:demo after /reload")
        if b"/skill:demo" not in output:
            raise SystemExit("completion did not apply to the input line")
        # The completion applied the first match; append args and submit,
        # then wait for a new request body on the fixture server.
        count_before = len(server_bodies())
        send(fd, output, status, pid, b"do the demo\r", timeout=0.5)
        deadline = time.time() + 10.0
        while len(server_bodies()) == count_before and time.time() < deadline:
            time.sleep(0.05)
        if len(server_bodies()) == count_before:
            raise SystemExit("expanded /skill:demo prompt did not reach the fixture provider")
        bodies = server_bodies()
        if not bodies:
            raise SystemExit("no request body captured after the skill expansion")
        body = bodies[-1]
        payload = json.loads(body)
        system_text = ""
        user_text = ""
        for message in payload.get("messages", []):
            if message.get("role") == "system":
                system_text += message.get("content", "")
            elif message.get("role") == "user":
                user_text += message.get("content", "")
        if "<available_skills>" not in system_text or "<name>demo</name>" not in system_text:
            raise SystemExit("system prompt after /reload lacks the skills block")
        if '<skill name="demo"' not in user_text or "References are relative to" not in user_text:
            raise SystemExit("prompt does not carry the expanded skill block")
        if "do the demo" not in user_text:
            raise SystemExit("prompt does not carry the /skill:name arguments")
        quit_tui(fd, output, status, pid)
    finally:
        close(fd, pid)

    # Phase C: --no-skills disables discovery even though the skill file is
    # still on disk.
    pid, fd = launch(["--no-skills"])
    output = bytearray()
    status = None
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        if not collect(fd, output, status, pid, b"\x1b[>1u", timeout=10.0):
            raise SystemExit("TUI did not become ready for keyboard input")
        if not send(fd, output, status, pid, b"/skill\r", b"No skills found in user or project skills directories", timeout=5.0):
            raise SystemExit("--no-skills did not disable the skills list")
        if not send(fd, output, status, pid, b"/skill:demo hi\r", b"Unknown command", timeout=5.0):
            raise SystemExit("--no-skills still expanded /skill:demo")
        quit_tui(fd, output, status, pid)
    finally:
        close(fd, pid)
finally:
    server.terminate()
    try:
        server.wait(timeout=3)
    except subprocess.TimeoutExpired:
        server.kill()
    shutil.rmtree(root, ignore_errors=True)

print("e2e: skills /reload lifecycle, expansion and --no-skills gating OK")
PY
