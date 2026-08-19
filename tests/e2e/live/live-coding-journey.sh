#!/bin/sh
set -eu

# Real DeepSeek coding journey (opt-in, cost-bounded).  Skipped by default
# (make e2e stays offline/mocked): set ADOU_LIVE_JOURNEY=1 to run two rounds
# against the live model in an isolated workspace:
#
#   Round 1: read fib.py -> edit (implement an iterative fibonacci) -> bash
#            (run it) -> final answer; the Pi v3 session is persisted.
#   PTY bridge: the same session is reopened in the TUI offline and the
#            round-1 history must render.
#   Round 2: --session <file> follow-up ("make it recursive") -> the model
#            must build on the round-1 edit, then answer.
#
# Parameters follow docs/porting-plan.md cost constraints: thinking off,
# bounded max tokens, at most one controlled retry.  The test key is passed
# via the environment and never printed; only usage/cost estimates derived
# from the persisted session are reported.
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

if [ "${ADOU_LIVE_JOURNEY:-0}" != "1" ]; then
    echo "e2e: live coding journey skipped (set ADOU_LIVE_JOURNEY=1 to enable)"
    exit 0
fi

if [ "${DEEPSEEK_TEST_API_KEY_IS_EXPLICIT:-0}" != "1" ]; then
    echo "e2e: live coding journey requires DEEPSEEK_TEST_API_KEY or DEEPSEEK_API_KEY" >&2
    exit 1
fi
deepseek_log_key_state

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-live-journey.XXXXXX")
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

work_dir="$tmp_dir/work"
session_dir="$tmp_dir/sessions"
mkdir -p "$work_dir" "$session_dir"

cat > "$work_dir/fib.py" <<'PY'
def fib(n):
    # TODO: implement fibonacci
    return 0


if __name__ == "__main__":
    print(fib(10))
PY

round_one_out="$tmp_dir/round1.jsonl"
round_two_out="$tmp_dir/round2.jsonl"
round_one_err="$tmp_dir/round1.err"
round_two_err="$tmp_dir/round2.err"

export DEEPSEEK_API_KEY="${DEEPSEEK_TEST_API_KEY}"

if ! (
    cd "$work_dir"
    ADOU_CODING_AGENT_DIR="$tmp_dir/agent" \
    ADOU_SESSION_DIR="$session_dir" \
    "$binary" --provider deepseek --model "${DEEPSEEK_TEST_MODEL}" --thinking off \
        --mode json --no-context-files --max-tokens 4096 --max-retries 1 \
        --timeout-ms 180000 --session-dir "$session_dir" \
        'Read fib.py, use the edit tool to implement an iterative fibonacci function that returns the nth fibonacci number, then run it with bash and confirm it prints the expected value.'
) > "$round_one_out" 2> "$round_one_err"; then
    echo 'e2e: live coding journey round 1 failed' >&2
    cat "$round_one_err" >&2
    cat "$round_one_out" >&2
    exit 1
fi

session_file=$(ls "$session_dir"/*.jsonl 2>/dev/null | head -n 1)
if [ -z "$session_file" ]; then
    echo 'e2e: live coding journey did not persist a session file' >&2
    exit 1
fi

python3 - "$session_file" "$work_dir" 1 <<'PY'
import json
import sys
import os

path, work, target_rounds = sys.argv[1:4]
entries = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
messages = [entry["message"] for entry in entries if entry.get("type") == "message"]
users = [m for m in messages if m.get("role") == "user"]
if len(users) != int(target_rounds):
    raise SystemExit(f"live journey: expected {target_rounds} user messages, got {len(users)}")
tool_calls = [m for m in messages if m.get("role") == "assistant"
              and any(isinstance(c, dict) and c.get("type") == "toolCall"
                      for c in m.get("content", []))]
names = []
for m in tool_calls:
    for c in m.get("content", []):
        if isinstance(c, dict) and c.get("type") == "toolCall":
            names.append(c.get("name"))
for required in ("read", "edit", "bash"):
    if required not in names:
        raise SystemExit(f"live journey: round 1 tool chain missing {required}: {names}")
results = [m for m in messages if m.get("role") == "toolResult"]
if any(r.get("isError") is True for r in results):
    raise SystemExit(f"live journey: a round-1 tool result errored: {results!r}")
call_ids = []
for m in tool_calls:
    for c in m.get("content", []):
        if isinstance(c, dict) and c.get("type") == "toolCall":
            call_ids.append(c.get("id"))
result_ids = [r.get("toolCallId") for r in results]
if not all(call_id in result_ids for call_id in call_ids):
    raise SystemExit(f"live journey: unmatched tool call/result ids: {call_ids} vs {result_ids}")
if not messages or messages[-1].get("role") != "assistant":
    raise SystemExit(f"live journey: no final assistant message: {messages[-1]!r}")
final = messages[-1]
final_blocks = [c for c in final.get("content", []) if isinstance(c, dict) and c.get("type") == "text"]
if not final_blocks or not final_blocks[0].get("text"):
    raise SystemExit(f"live journey: final assistant message has no text: {final!r}")
with open(os.path.join(work, "fib.py"), encoding="utf-8") as stream:
    fib_text = stream.read()
if "TODO" in fib_text:
    raise SystemExit("live journey: fib.py still contains the TODO marker")
if "def fib" not in fib_text:
    raise SystemExit("live journey: fib.py no longer defines fib")
print("live journey round 1: read+edit+bash chain, final answer and file result OK")
PY

# PTY resume bridge: reopen the SAME live session in the TUI offline and
# assert the round-1 history renders (same boundary as the local journey:
# PTY is limited to offline history rendering).
ADOU_BIN="$binary" SESSION_FILE="$session_file" AGENT_DIR="$tmp_dir/agent" \
    SESSION_DIR="$session_dir" python3 - <<'PY'
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import termios
import time

binary = os.environ["ADOU_BIN"]
session = os.environ["SESSION_FILE"]
agent_dir = os.environ["AGENT_DIR"]
os.makedirs(agent_dir, exist_ok=True)
open(os.path.join(agent_dir, ".adou-setup"), "w").close()
env = os.environ.copy()
env.update(
    {
        "ADOU_CODING_AGENT_DIR": agent_dir,
        "ADOU_SESSION_DIR": os.environ["SESSION_DIR"],
    }
)

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(
        binary,
        [
            binary,
            "--offline",
            "--no-context-files",
            "--session",
            session,
            "--provider",
            "deepseek",
            "--model",
            "deepseek-v4-flash",
        ],
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


try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    collect(timeout=1.0)
    if not collect(b"fib.py", timeout=8.0):
        raise SystemExit("PTY resume did not render the live round-1 history")
    os.write(fd, b"/quit\r")
    collect(timeout=6.0)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
    exit_code = os.waitstatus_to_exitcode(status)
    if exit_code != 0:
        raise SystemExit(f"PTY resume TUI exited with status {exit_code}")
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
PY

if ! (
    cd "$work_dir"
    ADOU_CODING_AGENT_DIR="$tmp_dir/agent" \
    ADOU_SESSION_DIR="$session_dir" \
    "$binary" --provider deepseek --model "${DEEPSEEK_TEST_MODEL}" --thinking off \
        --mode json --no-context-files --max-tokens 4096 --max-retries 1 \
        --timeout-ms 180000 --session "$session_file" \
        'Now modify the fibonacci function to be recursive using the edit tool, run it again with bash, and confirm it still prints the expected value.'
) > "$round_two_out" 2> "$round_two_err"; then
    echo 'e2e: live coding journey round 2 failed' >&2
    cat "$round_two_err" >&2
    cat "$round_two_out" >&2
    exit 1
fi

python3 - "$session_file" "$work_dir" 2 <<'PY'
import json
import os
import re
import sys

path, work, target_rounds = sys.argv[1:4]
entries = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
messages = [entry["message"] for entry in entries if entry.get("type") == "message"]
users = [m for m in messages if m.get("role") == "user"]
if len(users) != int(target_rounds):
    raise SystemExit(f"live journey: expected {target_rounds} user messages, got {len(users)}")
tool_calls = [m for m in messages if m.get("role") == "assistant"
              and any(isinstance(c, dict) and c.get("type") == "toolCall"
                      for c in m.get("content", []))]
results = [m for m in messages if m.get("role") == "toolResult"]
if not tool_calls:
    raise SystemExit("live journey: round 2 made no tool calls")
if not results or any(r.get("isError") is True for r in results):
    raise SystemExit(f"live journey: round 2 tool results errored: {results!r}")
call_ids = []
for m in tool_calls:
    for c in m.get("content", []):
        if isinstance(c, dict) and c.get("type") == "toolCall":
            call_ids.append(c.get("id"))
result_ids = [r.get("toolCallId") for r in results]
if not all(call_id in result_ids for call_id in call_ids):
    raise SystemExit("live journey: round 2 unmatched tool call/result ids")
if not messages or messages[-1].get("role") != "assistant":
    raise SystemExit("live journey: round 2 has no final assistant message")
final = messages[-1]
final_blocks = [c for c in final.get("content", []) if isinstance(c, dict) and c.get("type") == "text"]
if not final_blocks or not final_blocks[0].get("text"):
    raise SystemExit(f"live journey: round 2 final assistant message has no text: {final!r}")
with open(os.path.join(work, "fib.py"), encoding="utf-8") as stream:
    fib_text = stream.read()
if not re.search(r"fib\(\s*n\s*-\s*1\s*\)", fib_text):
    raise SystemExit("live journey: fib.py was not made recursive in round 2")

usage_input = sum(m.get("usage", {}).get("input", 0) for m in messages)
usage_output = sum(m.get("usage", {}).get("output", 0) for m in messages)
usage_cache = sum(m.get("usage", {}).get("cacheRead", 0) for m in messages)
usage_total = sum(m.get("usage", {}).get("totalTokens", 0) for m in messages)
cost_total = sum(m.get("usage", {}).get("cost", {}).get("total", 0.0) for m in messages)
print(f"live journey round 2: recursive edit applied, final answer OK")
print(f"live journey usage (from session): input={usage_input} output={usage_output} "
      f"cacheRead={usage_cache} totalTokens={usage_total} estimatedCost=~${cost_total:.6f}")
PY

echo "e2e: live coding journey passed with ${DEEPSEEK_TEST_MODEL_REF}"
