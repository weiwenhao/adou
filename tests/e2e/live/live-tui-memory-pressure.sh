#!/bin/sh
set -eu

# Real-provider TUI memory regression. It is deliberately opt-in because it
# spends provider quota and needs a configured DeepSeek key. The scenario
# mirrors the interactive sequence that exposed the long-lived growth bug:
# greeting, model question, then the SVG animation request.
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi
binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary")

. "$(dirname -- "$0")/../lib/deepseek-test-config.sh"

if [ "${ADOU_LIVE_TUI_MEMORY:-0}" != "1" ]; then
    echo "e2e: live TUI memory regression skipped (set ADOU_LIVE_TUI_MEMORY=1 to enable)"
    exit 0
fi

if [ "${DEEPSEEK_TEST_API_KEY_IS_EXPLICIT:-0}" != "1" ] && [ "${ADOU_LIVE_TUI_MEMORY_USE_STORED_AUTH:-1}" != "1" ]; then
    echo "e2e: live TUI memory regression requires an API key or stored Adou auth" >&2
    exit 1
fi
if [ "${DEEPSEEK_TEST_API_KEY_IS_EXPLICIT:-0}" = "1" ]; then
    deepseek_log_key_state
else
    echo "deepseek-test-config: using stored Adou auth (key not exported)"
fi

root=$(mktemp -d "${TMPDIR:-/tmp}/adou-live-tui-memory.XXXXXX")
cleanup() {
    # Retained diagnostics must never retain the copied local credential.
    rm -f "$root/agent/auth.json"
    if [ "${ADOU_LIVE_TUI_KEEP:-0}" = "1" ]; then
        echo "e2e: keeping live memory artifacts at $root" >&2
    else
        rm -rf "$root"
    fi
}
trap cleanup EXIT HUP INT TERM

if [ "${DEEPSEEK_TEST_API_KEY_IS_EXPLICIT:-0}" = "1" ]; then
    export DEEPSEEK_API_KEY="${DEEPSEEK_TEST_API_KEY}"
else
    unset DEEPSEEK_API_KEY || true
fi
ADOU_BIN="$binary" \
ADOU_PROCESS_GROUP_HELPER="${ADOU_PROCESS_GROUP_HELPER:-$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/adou-process-group}" \
ADOU_MEMORY_ROOT="$root" \
ADOU_MEMORY_MODEL="$DEEPSEEK_TEST_MODEL_REF" \
ADOU_MEMORY_THINKING="${ADOU_LIVE_MEMORY_THINKING:-max}" \
ADOU_MEMORY_MAX_TOKENS="${ADOU_LIVE_MEMORY_MAX_TOKENS:-4096}" \
ADOU_MEMORY_LIMIT_MB="${ADOU_LIVE_MEMORY_LIMIT_MB:-1024}" \
ADOU_MEMORY_SAMPLE_MB="${ADOU_LIVE_MEMORY_SAMPLE_MB:-256}" \
python3 - <<'PY'
import errno
import fcntl
import os
import pty
import re
import select
import signal
import shutil
import subprocess
import sys
import termios
import time

binary = os.environ["ADOU_BIN"]
helper = os.environ["ADOU_PROCESS_GROUP_HELPER"]
root = os.environ["ADOU_MEMORY_ROOT"]
model = os.environ["ADOU_MEMORY_MODEL"]
thinking = os.environ["ADOU_MEMORY_THINKING"]
max_tokens = os.environ["ADOU_MEMORY_MAX_TOKENS"]
memory_limit = int(os.environ["ADOU_MEMORY_LIMIT_MB"]) * 1024**2
sample_threshold = int(os.environ["ADOU_MEMORY_SAMPLE_MB"]) * 1024**2

agent_dir = os.path.join(root, "agent")
session_dir = os.path.join(root, "sessions")
os.makedirs(agent_dir)
os.makedirs(session_dir)
open(os.path.join(agent_dir, ".adou-setup"), "w").close()
# Preserve the user's local credential source for this isolated process. The
# temporary copy is removed with the test directory and never enters output.
source_agent = os.environ.get("ADOU_CODING_AGENT_DIR", "")
if source_agent.startswith("~/"):
    source_agent = os.path.join(os.path.expanduser("~"), source_agent[2:])
if source_agent == "":
    source_agent = os.path.join(os.path.expanduser("~"), ".adou", "agent")
source_auth = os.path.join(source_agent, "auth.json")
if os.path.exists(source_auth):
    shutil.copyfile(source_auth, os.path.join(agent_dir, "auth.json"))
write_log = os.path.join(root, "tui-write.log")
debug_log = os.path.join(root, "debug.log")
sample_log = os.path.join(root, "memory.csv")

argv = [
    binary,
    "--approve",
    "--no-context-files",
    "--provider",
    "deepseek",
    "--model",
    model,
    "--thinking",
    thinking,
    "--max-tokens",
    max_tokens,
    "--max-retries",
    "0",
    "--timeout-ms",
    "120000",
    "--session-dir",
    session_dir,
]

env = os.environ.copy()
env.update(
    {
        "ADOU_CODING_AGENT_DIR": agent_dir,
        "ADOU_PROCESS_GROUP_HELPER": helper,
        "ADOU_TUI_WRITE_LOG": write_log,
        "ADOU_DEBUG": "1",
        "ADOU_DEBUG_FILE": debug_log,
    }
)

master, slave = os.openpty()
fcntl.ioctl(master, termios.TIOCSWINSZ, __import__("struct").pack("HHHH", 40, 140, 0, 0))
pid = os.fork()
if pid == 0:
    os.setsid()
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    if slave > 2:
        os.close(slave)
    os.chdir(root)
    os.execvpe(binary, argv, env)
    os._exit(127)

os.close(slave)
fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
raw = bytearray()
samples = []
last_footprint_sample = 0.0
sample_taken = False
emergency_stop = False


def read_output():
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EIO):
                return
            raise
        if not chunk:
            return
        raw.extend(chunk)


def process_memory():
    rss_text = subprocess.check_output(
        ["ps", "-o", "rss=", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL
    ).strip()
    rss = int(rss_text or "0") * 1024
    footprint = rss
    try:
        summary = subprocess.check_output(
            ["vmmap", "-summary", str(pid)], text=True, stderr=subprocess.DEVNULL
        )
        match = re.search(r"Physical footprint:\s+([0-9.]+)([KMG])", summary)
        if match:
            footprint = int(float(match.group(1)) * {"K": 1024, "M": 1024**2, "G": 1024**3}[match.group(2)])
    except (OSError, subprocess.CalledProcessError):
        pass
    return rss, footprint


def sample_memory(force=False):
    global last_footprint_sample, sample_taken, emergency_stop
    now = time.time()
    if not force and now - last_footprint_sample < 1.0:
        return
    rss, footprint = process_memory()
    last_footprint_sample = now
    samples.append((now, rss, footprint))
    with open(sample_log, "a", encoding="utf-8") as fh:
        fh.write("%.3f,%d,%d\n" % (now, rss, footprint))
    if footprint > sample_threshold and not sample_taken:
        sample_taken = True
        try:
            subprocess.run(["sample", str(pid), "3", "-file", os.path.join(root, "sample.txt")], check=False)
        except OSError:
            pass
    if footprint > memory_limit:
        emergency_stop = True
        raise RuntimeError(
            "physical footprint exceeded configured limit: %.1fMB > %.1fMB"
            % (footprint / 1024**2, memory_limit / 1024**2)
        )


def text_without_ansi(data):
    out = bytearray()
    i = 0
    while i < len(data):
        if data[i] != 0x1B:
            out.append(data[i])
            i += 1
            continue
        i += 1
        if i < len(data) and data[i] == ord("["):
            i += 1
            while i < len(data) and not 0x40 <= data[i] <= 0x7E:
                i += 1
            if i < len(data):
                i += 1
        elif i < len(data) and data[i] == ord("]"):
            i += 1
            while i < len(data):
                if data[i] == 0x07:
                    i += 1
                    break
                if data[i] == 0x1B and i + 1 < len(data) and data[i + 1] == ord("\\"):
                    i += 2
                    break
                i += 1
        else:
            i += 1
    return bytes(out)


def log_text():
    try:
        with open(write_log, "rb") as fh:
            return text_without_ansi(fh.read()).decode("utf-8", "replace")
    except OSError:
        return ""


def alive():
    waited, status = os.waitpid(pid, os.WNOHANG)
    if waited:
        raise RuntimeError("adou exited during live memory test: %s" % status)


def session_state():
    counts = {"user": 0, "assistant": 0}
    last_assistant_stop = ""
    try:
        names = sorted(name for name in os.listdir(session_dir) if name.endswith(".jsonl"))
    except OSError:
        return counts, last_assistant_stop
    if not names:
        return counts, last_assistant_stop
    try:
        with open(os.path.join(session_dir, names[-1]), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    entry = __import__("json").loads(line)
                except ValueError:
                    continue
                message = entry.get("message") if isinstance(entry, dict) else None
                role = message.get("role") if isinstance(message, dict) else None
                if role in counts:
                    counts[role] += 1
                if role == "assistant":
                    last_assistant_stop = message.get("stopReason", "")
    except OSError:
        pass
    return counts, last_assistant_stop


def wait_until_idle(timeout, expected_users, assistant_count_before):
    deadline = time.time() + timeout
    last_size = -1
    quiet_since = None
    while time.time() < deadline:
        read_output()
        sample_memory()
        alive()
        counts, last_assistant_stop = session_state()
        try:
            size = os.path.getsize(write_log)
        except OSError:
            size = 0
        complete = (
            counts["user"] >= expected_users
            and counts["assistant"] > assistant_count_before
            and last_assistant_stop in ("stop", "aborted", "error", "length")
        )
        if complete and size == last_size:
            quiet_since = quiet_since or time.time()
        else:
            quiet_since = None
        last_size = size
        if quiet_since is not None and time.time() - quiet_since >= 4.0:
            return
        time.sleep(0.1)
    raise RuntimeError("TUI did not become idle within %.0fs" % timeout)


def send_prompt(prompt, expected_users):
    counts_before, _ = session_state()
    os.write(master, (prompt + "\r").encode("utf-8"))
    wait_until_idle(600, expected_users, counts_before["assistant"])


try:
    deadline = time.time() + 30
    while time.time() < deadline:
        read_output()
        sample_memory()
        if "escape interrupt" in log_text():
            break
        alive()
        time.sleep(0.1)
    else:
        raise RuntimeError("TUI did not become ready")

    send_prompt("你好", 1)
    send_prompt("你是什么模型", 2)
    send_prompt("创建一个 HTML，内容是 SVG 绘制一个鹈鹕骑自行车的 2D 动画", 3)
    for _ in range(6):
        sample_memory(force=True)
        time.sleep(1)

    if not samples:
        raise RuntimeError("no memory samples collected")
    baseline = samples[0][2]
    maximum = max(item[2] for item in samples)
    final = samples[-1][2]
    growth = maximum - baseline
    print(
        "e2e: live TUI memory samples=%d rss_max=%.1fMB footprint_baseline=%.1fMB footprint_max=%.1fMB footprint_final=%.1fMB growth=%.1fMB"
        % (
            len(samples),
            max(item[1] for item in samples) / 1024**2,
            baseline / 1024**2,
            maximum / 1024**2,
            final / 1024**2,
            growth / 1024**2,
        )
    )
    if maximum > memory_limit or growth > memory_limit:
        raise RuntimeError("live TUI memory exceeded configured footprint/growth limit")
finally:
    if emergency_stop:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    else:
        try:
            os.write(master, b"/quit\r")
        except OSError:
            pass
    try:
        end = time.time() + (5 if emergency_stop else 15)
        while time.time() < end:
            read_output()
            waited, _ = os.waitpid(pid, os.WNOHANG)
            if waited:
                break
            time.sleep(0.1)
    except (OSError, ChildProcessError):
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
        os.close(master)
    except OSError:
        pass
PY
