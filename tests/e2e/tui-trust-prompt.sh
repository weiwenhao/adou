#!/bin/sh
set -eu

# PTY e2e for the startup project trust prompt (docs/porting-plan-100 B1.1):
# an unresolved 'ask' project hosting trust-requiring resources opens Pi's
# "Trust project folder?" selector at startup; session-only trust closes it
# with no persisted decision, dismissing leaves the untrusted banner, and a
# saved decision skips the prompt entirely.
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
root = tempfile.mkdtemp(prefix="adou-tui-trust-")
project = os.path.join(root, "project")
os.makedirs(os.path.join(project, ".adou", "skills", "demo"))
with open(os.path.join(project, ".adou", "skills", "demo", "SKILL.md"), "w", encoding="utf-8") as handle:
    handle.write("---\nname: demo\ndescription: demo skill\n---\nbody\n")
agent_dir = os.path.join(root, "agent")


def make_env():
    env = os.environ.copy()
    env.update(
        {
            "ADOU_CODING_AGENT_DIR": agent_dir,
            "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
        }
    )
    return env


ENV = make_env()


def spawn():
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(project)
        os.execvpe(
            binary,
            [binary, "--offline", "--no-context-files", "--no-session",
             "--provider", "deepseek", "--model", "deepseek-v4-flash"],
            ENV,
        )
    return pid, fd


class Session:
    def __init__(self):
        self.pid, self.fd = spawn()
        self.output = bytearray()
        self.status = None

    def collect(self, until=None, timeout=4.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if until is not None and until in self.output:
                return True
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    self.output.extend(os.read(self.fd, 65536))
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
            waited, child_status = os.waitpid(self.pid, os.WNOHANG)
            if waited:
                self.status = child_status
                break
        return until is not None and until in self.output

    def key(self, key_bytes, until=None, timeout=4.0):
        os.write(self.fd, key_bytes)
        time.sleep(0.05)
        return self.collect(until, timeout=timeout)

    def quit(self):
        os.write(self.fd, b"/quit\r")
        self.collect(timeout=6.0)
        if self.status is None:
            os.kill(self.pid, signal.SIGKILL)
            try:
                os.waitpid(self.pid, 0)
            except OSError:
                pass

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
        if self.status is None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                os.waitpid(self.pid, 0)
            except OSError:
                pass


def ready(session):
    return session.collect(b"\x1b[>1u", timeout=10.0)


try:
    # Scenario A: the unresolved 'ask' project opens the startup prompt and a
    # session-only trust choice closes it without persisting a decision.
    session = Session()
    try:
        fcntl.ioctl(session.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        if not ready(session) or not session.collect(b"Trust project folder?", timeout=5.0):
            raise SystemExit("startup trust prompt did not open for an ask project")
        session.collect(b"This allows Adou to load .adou resources and project .agents skills.", timeout=3.0)
        if b"This allows Adou to load .adou resources and project .agents skills." not in session.output:
            raise SystemExit("trust prompt consequence description missing")
        session.collect(timeout=0.5)
        for label in (b"Trust parent folder", b"Trust (this session only)", b"Do not trust"):
            if label not in session.output:
                raise SystemExit(f"trust prompt option missing: {label!r}")
        os.write(session.fd, b"\x1b[B")
        time.sleep(0.15)
        os.write(session.fd, b"\x1b[B")
        banner_mark = len(session.output)
        if not session.key(b"\r", b"Project trusted", timeout=4.0):
            raise SystemExit("session-only trust selection did not register")
        time.sleep(0.3)
        # Output is cumulative: the banner legitimately appeared in the
        # pre-trust frames, so only frames after the selection count.
        if b"This project is not trusted" in bytes(session.output[banner_mark:]):
            raise SystemExit("untrusted banner shown after session-only trust")
        trust_file = os.path.join(agent_dir, "trust.json")
        if os.path.exists(trust_file):
            raise SystemExit("session-only trust wrote a persisted decision")
        session.quit()
    finally:
        session.close()

    # Scenario B: dismissing the prompt leaves the project untrusted with the
    # upstream banner and still persists nothing.
    session = Session()
    try:
        fcntl.ioctl(session.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        if not ready(session) or not session.collect(b"Trust project folder?", timeout=5.0):
            raise SystemExit("dismiss scenario did not reopen the trust prompt")
        session.key(b"\x1b", timeout=4.0)
        time.sleep(0.3)
        if b"This project is not trusted" not in session.output:
            raise SystemExit("untrusted banner missing after dismissal")
        if os.path.exists(os.path.join(agent_dir, "trust.json")):
            raise SystemExit("dismissal wrote a persisted decision")
        session.quit()
    finally:
        session.close()

    # Scenario C: a saved decision skips the prompt; a saved false keeps the
    # banner without reopening the selector.  The store key must match the
    # runtime cwd, which resolves through /private on macOS.
    os.makedirs(agent_dir, exist_ok=True)
    with open(os.path.join(agent_dir, "trust.json"), "w", encoding="utf-8") as handle:
        json.dump({os.path.realpath(project): False}, handle)
    session = Session()
    try:
        fcntl.ioctl(session.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        if not ready(session):
            raise SystemExit("saved-decision TUI never became ready")
        has_banner = session.collect(b"This project is not trusted", timeout=5.0)
        if b"Trust project folder?" in session.output:
            raise SystemExit("saved decision still opened the trust prompt")
        if not has_banner:
            raise SystemExit("saved false decision lost the untrusted banner")
        session.quit()
    finally:
        session.close()
finally:
    shutil.rmtree(root, ignore_errors=True)
PY

echo "e2e: startup trust prompt session-only dismiss and saved decisions OK"
