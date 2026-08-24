#!/bin/sh
set -eu

# Batch 4 acceptance: a user remap in keybindings.json changes BOTH the
# dispatch behavior and the hint surfaces together; /reload re-reads the
# file and reports conflicts.
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
root = tempfile.mkdtemp(prefix="adou-tui-keybindings-")
agent = os.path.join(root, "agent")
env = os.environ.copy()
env.update(
    {
        "ADOU_CODING_AGENT_DIR": agent,
        "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
        # Fixture key so the seeded catalog models authenticate for cycling.
        "DEEPSEEK_API_KEY": "test-key",
    }
)
os.makedirs(agent, exist_ok=True)
open(os.path.join(agent, ".adou-setup"), "w").close()
# Seed the catalog fixture so two authenticated models exist for cycling.
store_fixture = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "lib",
    "pi-oracle",
    "fixtures",
    "batch1",
    "home",
    ".adou",
    "agent",
    "models-store.json",
)
if os.path.exists(store_fixture):
    shutil.copy(store_fixture, os.path.join(agent, "models-store.json"))
# Remap the model cycle: ctrl+p must stop cycling, shift+ctrl+m must cycle.
with open(os.path.join(agent, "keybindings.json"), "w") as raw:
    json.dump({"app.model.cycleForward": "shift+ctrl+m"}, raw)

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(
        binary,
        [binary, "--offline", "--no-context-files", "--no-session",
         "--provider", "deepseek", "--model", "deepseek-v4-flash"],
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


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    if not collect(b"\x1b[>1u", timeout=10.0):
        raise SystemExit("TUI did not become ready for keyboard input")
    collect(timeout=0.3)
    # The registry-derived startup header must be present (Pi compact line).
    if b"interrupt" not in bytes(output) or b"clear/exit" not in bytes(output):
        raise SystemExit("registry-derived startup header missing")

    # /hotkeys derives from the SAME registry: scroll to the remapped key
    # (the overlay shows a 12-row window).
    if not key(b"/hotkeys\r", b"Keyboard shortcuts", timeout=5.0):
        raise SystemExit("/hotkeys did not open")
    found_remap = False
    for _ in range(60):
        collect(timeout=0.2)
        if b"shift+ctrl+m  Cycle to next model" in bytes(output):
            found_remap = True
            break
        os.write(fd, b"\x1b[B")
        time.sleep(0.12)
    if not found_remap:
        raise SystemExit("/hotkeys does not show the remapped key")
    os.write(fd, b"\x1b")
    time.sleep(0.4)

    # Behavior: the default ctrl+p must NOT cycle the model anymore.
    if not key(b"\x10", b"", timeout=1.5):
        pass
    time.sleep(0.6)
    collect(timeout=0.5)
    before = bytes(output)
    os.write(fd, b"\x10")
    time.sleep(0.8)
    collect(timeout=0.5)
    if b"Model:" in bytes(output[len(before):]):
        raise SystemExit("ctrl+p still cycles the model after the remap")
    # The remapped key cycles: shift+ctrl+m (CSI-u 109;6).
    if not key(b"\x1b[109;6u", b"Switched to", timeout=5.0):
        print("DEBUG tail:", bytes(output[-900:]))
        raise SystemExit("shift+ctrl+m did not cycle the model")

    # /reload re-reads the file; a conflicting config is reported.
    with open(os.path.join(agent, "keybindings.json"), "w") as raw:
        json.dump(
            {
                "app.model.cycleForward": "shift+ctrl+m",
                "app.model.select": "shift+ctrl+m",
            },
            raw,
        )
    if not key(b"/reload\r", b"Keybinding conflicts", timeout=6.0):
        raise SystemExit("/reload did not report the keybinding conflict")

    os.write(fd, b"/quit\r")
    collect(timeout=6.0)
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
        except OSError:
            pass
        try:
            _, status = os.waitpid(pid, 0)
        except OSError:
            pass
    shutil.rmtree(root, ignore_errors=True)
PY

echo "e2e: keybinding remap updates dispatch, hints and /reload conflict report together"
