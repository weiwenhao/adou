#!/bin/sh
set -eu

# Real online TUI two-round coding journey (opt-in, cost-bounded).  Skipped
# by default (make e2e stays offline/mocked): set ADOU_LIVE_TUI_JOURNEY=1 to
# drive a real DeepSeek session entirely inside the TUI over a Python
# stdlib PTY:
#
#   Round 1 (one TUI process, online): the PTY submits a coding request that
#     forces the model to actually call read -> edit -> bash and end its
#     final answer with the stable marker ROUND1DONE (a markdown-safe
#     literal: underscores would be consumed as emphasis by the renderer).
#   Round 2 (same TUI process): a follow-up request that must build on the
#     round-1 edit (edit again + bash + ROUND2DONE), proving follow-up
#     and shared-session context in the interactive UI.
#   /quit: exit 0, terminal restored (termios compare + restore escape
#     sequences), no leftover processes.
#   Resume: a second TUI process reopens the same session offline
#     (--session <file> --offline) and must render both rounds' history with
#     their completion markers before quitting cleanly.
#
# Assertion authority is split deliberately: the session JSONL is the
# tool-order authority (toolCall/toolResult pairing, isError, final
# assistant text, usage/cost), while PI_TUI_WRITE_LOG provides the
# TUI-visible evidence (user request echo, tool rows, final answers) so the
# suite never infers UI success from the session file alone.  Provider
# non-compliance (wrong tool order, tool errors, missing completion marker,
# per-round timeouts) is retried once at the whole-scenario level; Adou
# product defects (TUI crash, missing render, broken resume, terminal not
# restored) fail immediately.  The test key is passed via the environment
# and never printed; only usage/cost estimates from the persisted session
# are reported.
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi
# The Makefile passes a repo-relative ADOU_BIN; absolutize it so the cwd
# changes inside the journey (tool execution workspace) cannot break it.
binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary")

# shellcheck source=../lib/deepseek-test-config.sh
. "$(dirname -- "$0")/../lib/deepseek-test-config.sh"

if [ "${ADOU_LIVE_TUI_JOURNEY:-0}" != "1" ]; then
    echo "e2e: live TUI coding journey skipped (set ADOU_LIVE_TUI_JOURNEY=1 to enable)"
    exit 0
fi

if [ "${DEEPSEEK_TEST_API_KEY_IS_EXPLICIT:-0}" != "1" ]; then
    echo "e2e: live TUI coding journey requires DEEPSEEK_TEST_API_KEY or DEEPSEEK_API_KEY" >&2
    exit 1
fi
deepseek_log_key_state

root=$(mktemp -d "${TMPDIR:-/tmp}/adou-live-tui-journey.XXXXXX")
if [ "${ADOU_LIVE_TUI_KEEP:-0}" != "1" ]; then
    cleanup() {
        rm -rf "$root"
    }
else
    # Diagnostic mode: keep the attempt directories for post-mortem.
    cleanup() {
        :
    }
fi
trap cleanup EXIT HUP INT TERM

# The key is inherited by both TUI processes via the environment only; it is
# never passed on the command line and never echoed by the suite.
export DEEPSEEK_API_KEY="${DEEPSEEK_TEST_API_KEY}"

overall_start=$(date +%s)
attempt=0
while :; do
    attempt=$((attempt + 1))
    run_dir="$root/attempt-$attempt"
    work_dir="$run_dir/work"
    session_dir="$run_dir/sessions"
    agent_dir="$run_dir/agent"
    mkdir -p "$work_dir" "$session_dir" "$agent_dir"
    # Pre-create the setup marker so the first-time setup overlay never
    # intercepts the PTY session.
    : > "$agent_dir/.adou-setup"

    cat > "$work_dir/compute.py" <<'PY'
def compute(x):
    # TODO: implement doubling
    return 0


if __name__ == "__main__":
    print(compute(21))
PY

    set +e
    ADOU_BIN="$binary" DEEPSEEK_TEST_MODEL="$DEEPSEEK_TEST_MODEL" \
        WORK_DIR="$work_dir" SESSION_DIR="$session_dir" AGENT_DIR="$agent_dir" \
        WRITE_LOG1="$run_dir/tui1.log" WRITE_LOG2="$run_dir/tui2.log" \
        FAILURE_CLASS="$run_dir/failure-class" \
        python3 - <<'PY'
import errno
import fcntl
import hashlib
import json
import os
import select
import signal
import struct
import subprocess
import sys
import termios
import time

binary = os.environ["ADOU_BIN"]
model = os.environ["DEEPSEEK_TEST_MODEL"]
work_dir = os.environ["WORK_DIR"]
session_dir = os.environ["SESSION_DIR"]
agent_dir = os.environ["AGENT_DIR"]
write_log1 = os.environ["WRITE_LOG1"]
write_log2 = os.environ["WRITE_LOG2"]
failure_class = os.environ["FAILURE_CLASS"]

ROUND_TIMEOUT = 300.0
STARTUP_TIMEOUT = 30.0
QUIT_TIMEOUT = 60.0
RESUME_TIMEOUT = 60.0

PROMPT1 = (
    "ROUND 1: Read compute.py, then use the edit tool to implement the doubling function: "
    "replace the TODO stub so compute(x) returns x doubled and remove the TODO comment. "
    "Then run the file with bash (python3 compute.py) and verify it prints 42. End your "
    "final answer with exactly the line ROUND1DONE."
)
PROMPT2 = (
    "ROUND 2: In the same session, modify the doubling implementation you created in the previous "
    "request: compute(x) must now return x tripled. Use the edit tool on compute.py, then run it "
    "with bash (python3 compute.py) and verify it prints 63. End your final answer with exactly "
    "the line ROUND2DONE."
)


def fail(kind, message):
    with open(failure_class, "w", encoding="utf-8") as fh:
        fh.write(kind + "\n")
    sys.stderr.write("live-tui-journey: " + message + "\n")
    for path in (write_log1, write_log2):
        tail = log_bytes(path)[-2048:]
        if tail:
            sys.stderr.write("live-tui-journey: tail of %s:\n%s\n" % (os.path.basename(path), tail.decode("utf-8", "replace")))
    sys.exit(42 if kind == "PROVIDER" else 1)


def log_bytes(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return b""


# The TUI writes a differential ANSI stream: rows carry inline SGR styling
# and OSC hyperlink spans, and long lines wrap across rows.  Byte searches
# against the raw log are therefore fragile (a phrase can sit between two
# styled spans or across a wrap boundary), so UI evidence is asserted on the
# normalized text: all escape sequences stripped and row breaks joined.
def strip_ansi(data):
    out = bytearray()
    index = 0
    length = len(data)
    while index < length:
        byte = data[index]
        if byte == 0x1B:
            if index + 1 < length and data[index + 1] == 0x5B:  # CSI
                index += 2
                while index < length and not 0x40 <= data[index] <= 0x7E:
                    index += 1
                index += 1
                continue
            if index + 1 < length and data[index + 1] == 0x5D:  # OSC
                index += 2
                while index < length:
                    if data[index] == 0x07:
                        index += 1
                        break
                    if data[index] == 0x1B and index + 1 < length and data[index + 1] == 0x5C:
                        index += 2
                        break
                    index += 1
                continue
            index += 2
            continue
        out.append(byte)
        index += 1
    return bytes(out)


def normalize_log(path):
    normalized = strip_ansi(log_bytes(path)).replace(b"\r\n", b" ")
    out = bytearray()
    previous_space = False
    for byte in normalized:
        if byte == 0x20:
            if previous_space:
                continue
            previous_space = True
        else:
            previous_space = False
        out.append(byte)
    return bytes(out)


def session_file():
    names = sorted(n for n in os.listdir(session_dir) if n.endswith(".jsonl"))
    return os.path.join(session_dir, names[0]) if names else None


def session_messages(strict=False):
    path = session_file()
    if path is None:
        return []
    messages = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                if strict:
                    fail("PRODUCT", "session JSONL contains an unparsable line: " + line[:200])
                continue
            if isinstance(entry, dict) and entry.get("type") == "message" and isinstance(entry.get("message"), dict):
                messages.append(entry["message"])
    return messages


def assistant_text(message):
    parts = message.get("content")
    if isinstance(parts, list):
        return "".join(c.get("text", "") for c in parts if isinstance(c, dict) and c.get("type") == "text")
    return ""


def last_assistant_text():
    for m in reversed(session_messages()):
        if m.get("role") == "assistant":
            return assistant_text(m)
    return ""


def calls_in(messages):
    calls = []
    for m in messages:
        if m.get("role") != "assistant":
            continue
        for c in m.get("content", []):
            if isinstance(c, dict) and c.get("type") == "toolCall":
                calls.append((c.get("name", ""), c.get("id", "")))
    return calls


class TuiProcess:
    def __init__(self, argv, write_log, label):
        self.label = label
        self.write_log = write_log
        self.raw = bytearray()
        self.master, self.slave = os.openpty()
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 120, 0, 0))
        self.initial_termios = termios.tcgetattr(self.slave)
        env = os.environ.copy()
        env.update(
            {
                "PI_CODING_AGENT_DIR": agent_dir,
                "PI_CODING_AGENT_SESSION_DIR": session_dir,
                "PI_TUI_WRITE_LOG": write_log,
            }
        )
        self.pid = os.fork()
        if self.pid == 0:
            # A controlling terminal is deliberately NOT acquired: on macOS
            # the parent then loses the ability to tcgetattr the slave once
            # the ctty-holding child exits (ENOTTY), which would make the
            # terminal-restore comparison impossible.
            try:
                os.setsid()
            except OSError:
                pass
            os.dup2(self.slave, 0)
            os.dup2(self.slave, 1)
            os.dup2(self.slave, 2)
            if self.slave > 2:
                os.close(self.slave)
            os.chdir(work_dir)
            os.execvpe(binary, [binary] + argv, env)
            os._exit(127)
        self.exit_status = None

    def poll(self, timeout=0.05):
        try:
            ready, _, _ = select.select([self.master], [], [], timeout)
        except OSError:
            ready = []
        if ready:
            try:
                chunk = os.read(self.master, 65536)
                if chunk:
                    self.raw.extend(chunk)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
        if self.exit_status is None:
            waited, status = os.waitpid(self.pid, os.WNOHANG)
            if waited:
                self.exit_status = status
        return self.exit_status

    def send(self, data):
        os.write(self.master, data)

    def wait_startup(self):
        deadline = time.time() + STARTUP_TIMEOUT
        while time.time() < deadline:
            self.poll()
            if log_bytes(self.write_log):
                return
            if self.exit_status is not None:
                self.dump_raw()
                fail(
                    "PRODUCT",
                    "%s exited during startup with status %s"
                    % (self.label, os.waitstatus_to_exitcode(self.exit_status)),
                )
            time.sleep(0.1)
        self.dump_raw()
        fail("PRODUCT", "%s produced no terminal output within the startup deadline" % self.label)

    def wait_idle(self, quiet_seconds, timeout, phase):
        # The marker render precedes the stream's terminal events.  Submitting
        # the next request (or /quit) while the previous stream is still
        # active would queue it as a streaming message instead of running it,
        # so wait for the write log to quiesce: no new frames (the spinner
        # keeps rendering while a stream is active) for quiet_seconds.
        last_size = -1
        stable_since = None
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.poll()
            size = len(log_bytes(self.write_log))
            if size == last_size:
                if stable_since is None:
                    stable_since = time.time()
                elif time.time() - stable_since >= quiet_seconds:
                    return
            else:
                stable_since = None
            last_size = size
            if self.exit_status is not None:
                self.dump_raw()
                fail(
                    "PRODUCT",
                    "%s exited with status %s while waiting for idle %s"
                    % (self.label, os.waitstatus_to_exitcode(self.exit_status), phase),
                )
            time.sleep(0.1)
        self.dump_raw()
        fail("PRODUCT", "%s did not become idle within %.0fs before %s" % (self.label, timeout, phase))

    def wait_round(self, marker_text, marker_bytes, deadline, phase):
        last_log_len = -1
        while time.time() < deadline:
            self.poll()
            log = normalize_log(self.write_log)
            if log and len(log) != last_log_len:
                last_log_len = len(log)
                if b"Request failed" in log:
                    self.dump_raw()
                    fail(
                        "PRODUCT",
                        "%s: TUI reported 'Request failed' during %s (submission race or product bug)"
                        % (self.label, phase),
                    )
            if marker_bytes in log and marker_text in last_assistant_text():
                return
            if self.exit_status is not None:
                self.dump_raw()
                fail(
                    "PRODUCT",
                    "%s exited during %s with status %s"
                    % (self.label, phase, os.waitstatus_to_exitcode(self.exit_status)),
                )
            time.sleep(0.25)
        if marker_text in last_assistant_text() and marker_bytes not in normalize_log(self.write_log):
            self.dump_raw()
            fail("PRODUCT", "%s: %s marker reached the session but never rendered in the TUI log" % (self.label, phase))
        self.dump_raw()
        fail(
            "PROVIDER",
            "%s: timed out after %.0fs waiting for final marker %r (provider non-compliance or outage)"
            % (self.label, ROUND_TIMEOUT, marker_text),
        )

    def drain(self):
        fcntl.fcntl(self.master, fcntl.F_SETFL, os.O_NONBLOCK)
        while True:
            try:
                chunk = os.read(self.master, 65536)
                if not chunk:
                    break
                self.raw.extend(chunk)
            except OSError as exc:
                if exc.errno in (errno.EIO, errno.EAGAIN):
                    break
                raise

    def quit(self):
        self.send(b"/quit\r")
        deadline = time.time() + QUIT_TIMEOUT
        while time.time() < deadline:
            self.poll()
            if self.exit_status is not None:
                break
            time.sleep(0.1)
        if self.exit_status is None:
            self.kill()
            self.dump_raw()
            fail("PRODUCT", "%s: /quit did not exit within %.0fs" % (self.label, QUIT_TIMEOUT))
        code = os.waitstatus_to_exitcode(self.exit_status)
        if code != 0:
            self.dump_raw()
            fail("PRODUCT", "%s: TUI exited with status %d on /quit" % (self.label, code))
        self.drain()
        tail = bytes(self.raw[-1024:])
        if b"\x1b[<u" not in tail or b"\x1b[?25h" not in tail:
            self.dump_raw()
            fail("PRODUCT", "%s: terminal restore sequences missing at the end of the output" % self.label)
        try:
            restored = termios.tcgetattr(self.slave) == self.initial_termios
        except Exception:
            self.dump_raw()
            fail("PRODUCT", "%s: could not compare terminal attributes after /quit" % self.label)
        if not restored:
            self.dump_raw()
            fail("PRODUCT", "%s: terminal attributes were not restored after /quit" % self.label)
        return code

    def assert_raw_mode_active(self, phase):
        try:
            current = termios.tcgetattr(self.slave)
        except Exception:
            self.dump_raw()
            fail("PRODUCT", "%s: could not probe terminal attributes during %s" % (self.label, phase))
        if current[3] & termios.ICANON:
            self.dump_raw()
            fail("PRODUCT", "%s: terminal was not in raw mode during %s" % (self.label, phase))

    def kill(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except OSError:
            pass

    def dump_raw(self):
        try:
            with open(self.write_log + ".raw", "wb") as fh:
                fh.write(bytes(self.raw))
        except OSError:
            pass

    def close(self):
        self.dump_raw()
        for fd in (self.slave, self.master):
            try:
                os.close(fd)
            except OSError:
                pass


def assert_session_jsonl():
    messages = session_messages(strict=True)
    users = [m for m in messages if m.get("role") == "user"]
    if len(users) != 2:
        fail("PRODUCT", "expected exactly 2 user messages, got %d" % len(users))
    if "compute.py" not in users[0].get("content", ""):
        fail("PRODUCT", "round-1 user message was not recorded in the session")
    if "doubling" not in users[0].get("content", ""):
        fail("PRODUCT", "round-1 user message content mismatch")
    if "previous request" not in users[1].get("content", "") or "tripled" not in users[1].get("content", ""):
        fail("PRODUCT", "round-2 user message does not reference the previous round's edit")
    assistants = [m for m in messages if m.get("role") == "assistant"]
    results = [m for m in messages if m.get("role") == "toolResult"]
    if not assistants or not results:
        fail("PRODUCT", "session lacks assistant messages or tool results")
    if any(r.get("isError") is True for r in results):
        fail("PROVIDER", "a tool result errored (isError=true): %r" % results)
    user_positions = [i for i, m in enumerate(messages) if m.get("role") == "user"]
    round1_msgs = messages[: user_positions[1]]
    round2_msgs = messages[user_positions[1]:]
    r1_calls = calls_in(round1_msgs)
    r2_calls = calls_in(round2_msgs)
    r1_names = [n for n, _ in r1_calls]
    r2_names = [n for n, _ in r2_calls]
    if "read" not in r1_names or "edit" not in r1_names or "bash" not in r1_names:
        fail("PROVIDER", "round 1 tool chain missing read/edit/bash: %r" % r1_names)
    if not (r1_names.index("read") < r1_names.index("edit") < r1_names.index("bash")):
        fail("PROVIDER", "round 1 tool order was not read, edit, bash: %r" % r1_names)
    if "edit" not in r2_names or "bash" not in r2_names:
        fail("PROVIDER", "round 2 tool chain missing edit/bash: %r" % r2_names)
    if not (r2_names.index("edit") < r2_names.index("bash")):
        fail("PROVIDER", "round 2 tool order was not edit before bash: %r" % r2_names)
    call_ids = [call_id for _, call_id in r1_calls + r2_calls]
    result_ids = [r.get("toolCallId") for r in results]
    if not all(call_id in result_ids for call_id in call_ids):
        fail("PRODUCT", "unmatched toolCall/toolResult ids: %r vs %r" % (call_ids, result_ids))
    r1_assistants = [m for m in round1_msgs if m.get("role") == "assistant"]
    if not r1_assistants or "ROUND1DONE" not in assistant_text(r1_assistants[-1]):
        fail("PROVIDER", "round 1 final assistant answer lacks ROUND1DONE")
    if "ROUND2DONE" not in assistant_text(assistants[-1]):
        fail("PROVIDER", "round 2 final assistant answer lacks ROUND2DONE")
    for phase, round_msgs, expected in (
        ("round 1", round1_msgs, "42"),
        ("round 2", round2_msgs, "63"),
    ):
        bash_ids = [call_id for name, call_id in calls_in(round_msgs) if name == "bash"]
        output = ""
        for r in results:
            if r.get("toolCallId") in bash_ids:
                for part in r.get("content", []):
                    if isinstance(part, dict):
                        output += part.get("text", "")
        if expected not in output:
            fail("PROVIDER", "%s bash verification output missing %r: %r" % (phase, expected, output[:200]))
    compute_path = os.path.join(work_dir, "compute.py")
    with open(compute_path, encoding="utf-8") as fh:
        compute_text = fh.read()
    if "TODO" in compute_text:
        fail("PROVIDER", "compute.py still contains the TODO marker after round 1")
    if "def compute" not in compute_text:
        fail("PRODUCT", "compute.py no longer defines compute()")
    proc = subprocess.run(
        ["python3", "compute.py"], cwd=work_dir, capture_output=True, text=True, timeout=30
    )
    if proc.returncode != 0 or "63" not in proc.stdout:
        fail("PROVIDER", "final compute.py does not print 63: rc=%s out=%r err=%r" % (proc.returncode, proc.stdout, proc.stderr))
    return messages


def assert_tui_visible(write_log, round1_echo, round2_echo):
    log = normalize_log(write_log)
    if round1_echo not in log:
        fail("PRODUCT", "TUI log missing the round-1 user request echo")
    if round2_echo not in log:
        fail("PRODUCT", "TUI log missing the round-2 user request echo")
    if b"\xe2\x9c\x93 read" not in log:
        fail("PRODUCT", "TUI log missing the rendered read tool result row")
    if b"\xe2\x9c\x93 bash" not in log:
        fail("PRODUCT", "TUI log missing the rendered bash tool result row")
    if log.count(b"\xe2\x9c\x93 edit") < 2:
        fail("PRODUCT", "TUI log missing both rounds' rendered edit tool result rows")
    if b"ROUND1DONE" not in log or b"ROUND2DONE" not in log:
        fail("PRODUCT", "TUI log missing a round completion marker render")


try:
    tui = TuiProcess(
        [
            "--provider",
            "deepseek",
            "--model",
            model,
            "--thinking",
            "off",
            "--max-tokens",
            "4096",
            "--max-retries",
            "1",
            "--timeout-ms",
            "180000",
            "--session-dir",
            session_dir,
            "--no-context-files",
        ],
        write_log1,
        "live TUI",
    )
    tui.wait_startup()

    round1_start = time.time()
    tui.send((PROMPT1 + "\r").encode("utf-8"))
    tui.wait_round("ROUND1DONE", b"ROUND1DONE", time.time() + ROUND_TIMEOUT, "round 1")
    round1_elapsed = time.time() - round1_start
    # The TUI must still own the terminal in raw mode between rounds.
    tui.assert_raw_mode_active("round 1")
    tui.wait_idle(1.0, 15.0, "round 2 submission")

    round2_start = time.time()
    tui.send((PROMPT2 + "\r").encode("utf-8"))
    tui.wait_round("ROUND2DONE", b"ROUND2DONE", time.time() + ROUND_TIMEOUT, "round 2")
    round2_elapsed = time.time() - round2_start

    messages = assert_session_jsonl()
    assert_tui_visible(write_log1, b"returns x doubled", b"must now return x tripled")

    tui.wait_idle(1.0, 15.0, "/quit")
    tui.quit()
    tui.close()

    session_path = session_file()
    if session_path is None:
        fail("PRODUCT", "no session JSONL was persisted")
    before_hash = hashlib.sha256(open(session_path, "rb").read()).hexdigest()

    resume = TuiProcess(
        [
            "--offline",
            "--no-context-files",
            "--session",
            session_path,
            "--provider",
            "deepseek",
            "--model",
            model,
        ],
        write_log2,
        "resume TUI",
    )
    resume.wait_startup()
    resume_deadline = time.time() + RESUME_TIMEOUT
    while time.time() < resume_deadline:
        resume.poll()
        resume_log = normalize_log(write_log2)
        if (
            b"ROUND1DONE" in resume_log
            and b"ROUND2DONE" in resume_log
            and b"\xe2\x9c\x93 edit" in resume_log
        ):
            break
        if resume.exit_status is not None:
            fail(
                "PRODUCT",
                "resume TUI exited with status %s before rendering history"
                % os.waitstatus_to_exitcode(resume.exit_status),
            )
        time.sleep(0.2)
    else:
        resume.dump_raw()
        fail("PRODUCT", "resume TUI did not render both rounds' completion markers")
    resume.wait_idle(1.0, 15.0, "/quit")
    resume.quit()
    resume.close()
    after_hash = hashlib.sha256(open(session_path, "rb").read()).hexdigest()
    if before_hash != after_hash:
        fail("PRODUCT", "offline resume modified the session JSONL")

    assistant_msgs = [m for m in session_messages(strict=True) if m.get("role") == "assistant"]
    requests = len(assistant_msgs)
    total_input = sum(m.get("usage", {}).get("input", 0) for m in assistant_msgs)
    total_output = sum(m.get("usage", {}).get("output", 0) for m in assistant_msgs)
    total_cache = sum(m.get("usage", {}).get("cacheRead", 0) for m in assistant_msgs)
    total_tokens = sum(m.get("usage", {}).get("totalTokens", 0) for m in assistant_msgs)
    total_cost = sum(m.get("usage", {}).get("cost", {}).get("total", 0.0) for m in assistant_msgs)
    print("live-tui-journey: round 1 %.1fs, round 2 %.1fs, offline resume ok" % (round1_elapsed, round2_elapsed))
    print(
        "live-tui-journey: model=%s provider requests=%d (2 rounds, thinking off, max-retries 1)"
        % (model, requests)
    )
    print(
        "live-tui-journey: tool chains round1=read,edit,bash round2=edit,bash; final markers rendered"
    )
    print(
        "live-tui-journey usage (from session): input=%d output=%d cacheRead=%d totalTokens=%d estimatedCost=~$%.6f"
        % (total_input, total_output, total_cache, total_tokens, total_cost)
    )
except SystemExit:
    raise
except Exception as exc:  # noqa: BLE001 - classification wrapper for driver bugs
    import traceback

    traceback.print_exc()
    fail("PRODUCT", "driver exception: %r" % (exc,))
PY
    driver_rc=$?
    set -e

    if [ "$driver_rc" -eq 0 ]; then
        break
    fi
    failed_class=$(cat "$run_dir/failure-class" 2>/dev/null || echo PRODUCT)
    echo "e2e: live TUI journey attempt $attempt failed (class=$failed_class)" >&2
    if [ "$failed_class" = "PROVIDER" ] && [ "$attempt" -lt 2 ]; then
        echo "e2e: live TUI journey: provider anomaly detected, retrying the scenario once" >&2
        continue
    fi
    echo "e2e: live TUI journey failed definitively (attempt $attempt)" >&2
    exit 1
done
overall_elapsed=$(($(date +%s) - overall_start))
echo "e2e: live TUI journey passed in ${overall_elapsed}s (attempt $attempt)"

# No leftover TUI or tool processes after both clean quits.
sleep 1
leftovers=$(pgrep -fl "$binary" 2>/dev/null || true)
compute_leftovers=$(pgrep -fl "compute.py" 2>/dev/null || true)
if [ -n "$leftovers" ] || [ -n "$compute_leftovers" ]; then
    echo "e2e: live TUI journey left processes behind:" >&2
    echo "$leftovers" >&2
    echo "$compute_leftovers" >&2
    exit 1
fi
echo "e2e: live TUI journey: no leftover adou or tool processes"
echo "e2e: live TUI journey passed with ${DEEPSEEK_TEST_MODEL_REF}"
