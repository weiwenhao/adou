#!/bin/sh
set -eu

# Live macOS reproducer for the smallest user-reported crash sequence.
#
# Fresh process, in the same working directory as the report:
#
#     adou
#     画一个秦始皇骑北极熊
#     [while it is Thinking] press Escape once
#
# This deliberately uses the normal DeepSeek configuration and sends a real
# Escape byte through the PTY after generation has started.  It does not add
# gh or a synthetic provider response.  It is kept outside tests/e2e because
# it consumes provider quota and is intended for a real macOS run only.

binary=${ADOU_BIN:-$(command -v adou 2>/dev/null || true)}
if [ -z "$binary" ] || [ ! -x "$binary" ]; then
    echo "repro: Adou binary not found; set ADOU_BIN" >&2
    exit 2
fi

case "$binary" in
    /*) ;;
    *) binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary") ;;
esac

helper=${ADOU_PROCESS_GROUP_HELPER:-$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/adou-process-group}
if [ ! -x "$helper" ]; then
    echo "repro: process-group helper not found: $helper" >&2
    exit 2
fi

repro_dir=${ADOU_REPRO_DIR:-$PWD}
if [ ! -d "$repro_dir" ]; then
    echo "repro: working directory not found: $repro_dir" >&2
    exit 2
fi

log_dir=${ADOU_REPRO_OUTPUT_DIR:-${TMPDIR:-/tmp}/adou-qin-polar-bear-repro-$(date +%Y%m%d-%H%M%S)-$$}
mkdir -p "$log_dir"

ADOU_BIN="$binary" \
ADOU_PROCESS_GROUP_HELPER="$helper" \
ADOU_REPRO_DIR="$repro_dir" \
ADOU_REPRO_OUTPUT_DIR="$log_dir" \
python3 - <<'PY'
import errno
import fcntl
import glob
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

binary = os.environ["ADOU_BIN"]
helper = os.environ["ADOU_PROCESS_GROUP_HELPER"]
repro_dir = os.environ["ADOU_REPRO_DIR"]
log_dir = os.environ["ADOU_REPRO_OUTPUT_DIR"]
prompt = "画一个秦始皇骑北极熊"
timeout_seconds = float(os.environ.get("ADOU_REPRO_TIMEOUT", "75"))
# The report's manual sequence crashed about ten seconds after the prompt.
# Keep that timing as the default; the variable is exposed for reproducing a
# different point in the same in-flight request.
escape_delay_seconds = float(os.environ.get("ADOU_REPRO_ESCAPE_DELAY", "10"))
ctrl_c_first = os.environ.get("ADOU_REPRO_CTRL_C_FIRST", "0") == "1"

os.makedirs(log_dir, exist_ok=True)
raw_output_path = os.path.join(log_dir, "pty-output.bin")
metadata_path = os.path.join(log_dir, "metadata.json")
report_dir = os.path.expanduser("~/Library/Logs/DiagnosticReports")
reports_before = set(glob.glob(os.path.join(report_dir, "adou-*.ips")))

env = os.environ.copy()
env.update(
    {
        "ADOU_PROCESS_GROUP_HELPER": helper,
        "TERM": "xterm-256color",
    }
)

# Keep the invocation identical to the reported terminal session: `adou`.
# The provider/model are inherited from the user's normal Adou configuration.
args = [binary]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(repro_dir)
    os.execvpe(binary, args, env)

output = bytearray()
child_status = None
escape_sent = False


def collect(until=None, deadline=None):
    global child_status
    if deadline is None:
        deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline:
        if until is not None and until in output:
            return True
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    chunk = b""
                else:
                    raise
            if chunk:
                output.extend(chunk)
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited:
            child_status = status
            return until is not None and until in output
    return until is not None and until in output


def wait_for_exit(deadline):
    global child_status
    while child_status is None and time.monotonic() < deadline:
        collect(deadline=min(deadline, time.monotonic() + 0.25))
    return child_status is not None


def status_description(status):
    if status is None:
        return "still-running"
    if os.WIFSIGNALED(status):
        return "signal-%d" % os.WTERMSIG(status)
    return "exit-%d" % os.waitstatus_to_exitcode(status)


try:
    with open(raw_output_path, "wb") as raw:
        fcntl_winsize = struct.pack("HHHH", 24, 100, 0, 0)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, fcntl_winsize)

        ready = collect(b"\x1b[>1u", time.monotonic() + 15.0)
        if not ready and child_status is not None:
            raise SystemExit("repro: Adou exited before the TUI became ready (%s)" % status_description(child_status))
        if not ready:
            raise SystemExit("repro: TUI did not become ready within 15 seconds")

        # This is the complete user input for the minimal reproducer.
        os.write(fd, (prompt + "\r").encode("utf-8"))
        thinking = collect(b"Thinking...", time.monotonic() + 20.0)
        if not thinking and child_status is not None:
            raise SystemExit("repro: Adou exited before generation started (%s)" % status_description(child_status))
        if not thinking:
            raise SystemExit("repro: generation did not show Thinking... within 20 seconds")

        # Reproduce the user action while the request is still running.  The
        # default is the minimal variant: Escape directly.  Set
        # ADOU_REPRO_CTRL_C_FIRST=1 for the earlier Ctrl+C-then-Escape variant.
        collect(deadline=time.monotonic() + escape_delay_seconds)
        if ctrl_c_first:
            os.write(fd, b"\x03")
            collect(deadline=time.monotonic() + 0.2)
        os.write(fd, b"\x1b")
        escape_sent = True
        wait_for_exit(time.monotonic() + timeout_seconds)

        # A non-crashing run remains interactive.  Exit it cleanly so the
        # harness never leaves a TUI process behind, then classify the result
        # as "not reproduced".
        if child_status is None:
            try:
                os.write(fd, b"/quit\r")
            except OSError:
                pass
            wait_for_exit(time.monotonic() + 8.0)

        if child_status is None:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
            _, child_status = os.waitpid(pid, 0)

        # Drain bytes already queued by the PTY before writing the artifact.
        try:
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                output.extend(chunk)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
        raw.write(output)

    reports_after = set()
    # macOS writes the DiagnosticReports file asynchronously after the child
    # exits.  Give it a short window so the artifact records the crash report
    # instead of racing it.
    for _ in range(15):
        reports_after = set(glob.glob(os.path.join(report_dir, "adou-*.ips")))
        if reports_after - reports_before:
            break
        time.sleep(0.2)
    new_reports = sorted(reports_after - reports_before)
    metadata = {
        "binary": binary,
        "workingDirectory": repro_dir,
        "prompt": prompt,
        "args": args,
        "timeoutSeconds": timeout_seconds,
        "escapeDelaySeconds": escape_delay_seconds,
        "ctrlCFirst": ctrl_c_first,
        "escapeSent": escape_sent,
        "status": status_description(child_status),
        "exitCode": os.waitstatus_to_exitcode(child_status),
        "newCrashReports": new_reports,
        "ptyOutput": raw_output_path,
    }
    with open(metadata_path, "w", encoding="utf-8") as metadata_file:
        json.dump(metadata, metadata_file, ensure_ascii=False, indent=2)
        metadata_file.write("\n")

    if os.WIFSIGNALED(child_status) and os.WTERMSIG(child_status) in (signal.SIGSEGV, signal.SIGABRT):
        print("repro: REPRODUCED %s" % status_description(child_status))
        print("repro: prompt=%s" % prompt)
        print("repro: output=%s" % raw_output_path)
        print("repro: crashReports=%s" % (", ".join(new_reports) if new_reports else "none observed yet"))
        raise SystemExit(0)

    print("repro: NOT REPRODUCED (%s)" % status_description(child_status))
    print("repro: prompt=%s" % prompt)
    print("repro: output=%s" % raw_output_path)
    print("repro: metadata=%s" % metadata_path)
    raise SystemExit(1)
finally:
    try:
        os.close(fd)
    except OSError:
        pass
    if child_status is None:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass
PY
