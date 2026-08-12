#!/bin/sh
set -eu

# TUI input latency regression: with the full model catalog (~1200 models)
# and an isolated agent dir, a typed character must echo in well under a
# second.  This guards the per-frame authenticated_provider_count hot-path
# bug (5.9s echo) where every render rescanned models.all() and re-read
# auth.json per model.  Threshold has headroom for slow machines but stays
# far below the original ~5.9s.
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
import sys
import tempfile
import termios
import time

binary = os.environ["ADOU_BIN"]
root = tempfile.mkdtemp(prefix="adou-tui-latency-")

env = os.environ.copy()
env.update(
    {
        "PI_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "PI_CODING_AGENT_SESSION_DIR": os.path.join(root, "sessions"),
    }
)
os.makedirs(os.path.join(root, "agent"), exist_ok=True)
open(os.path.join(root, "agent", ".adou-setup"), "w").close()
# A credential file must exist so the pre-fix hot path really re-read and
# re-parsed auth.json on every render frame (the regression it guards).
with open(os.path.join(root, "agent", "auth.json"), "w") as auth_file:
    auth_file.write(
        json.dumps(
            {
                "openai": {
                    "credential_type": "api_key",
                    "key": "sk-latency-fixture",
                }
            }
        )
    )

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(
        binary,
        [binary, "--offline", "--no-context-files", "--no-session"],
        env,
    )

output = bytearray()
status = None
echo_start = None
echo_elapsed = None


def collect(timeout=1.0):
    global status
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.01)
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


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    collect(timeout=2.0)

    # Warm up: wait for the first prompt frame.
    for _ in range(50):
        if b"adou" in output or len(output) > 0:
            break
        collect(timeout=0.1)

    # Send one character and measure until it is echoed by the editor.
    before = len(output)
    echo_start = time.monotonic()
    os.write(fd, b"a")
    deadline = time.time() + 3.0
    while time.time() < deadline:
        collect(timeout=0.02)
        if len(output) > before:
            echo_elapsed = time.monotonic() - echo_start
            break
    if echo_elapsed is None:
        raise SystemExit("no echo observed after typing a character")

    limit = 1.5
    print(f"echo latency: {echo_elapsed:.3f}s (limit {limit}s)")
    if echo_elapsed > limit:
        raise SystemExit(
            f"TUI input echo too slow: {echo_elapsed:.3f}s > {limit}s "
            "(authenticated provider scan on the render hot path?)"
        )

    # Clean quit.
    os.write(fd, b"\x03")  # ctrl+c
    collect(timeout=1.0)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
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

echo "e2e: TUI input echo latency stays under the limit with the full model catalog"
