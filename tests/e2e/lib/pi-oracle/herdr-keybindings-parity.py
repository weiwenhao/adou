#!/usr/bin/env python3
"""Batch 4 keybindings parity over Herdr real terminals.

Drives Pi 0.82.1 (vendors/pi) and the built Adou binary through the SAME
key sequence in two fresh sibling panes with the SAME fixed environment and
a SHARED user keybindings.json (Pi config format) that remaps
app.model.cycleForward to shift+ctrl+m.

Contract:
  A. Startup: both sides render the registry-derived header hint line
     ('interrupt', 'clear/exit', '/ commands', '! bash').
  B. Input matrix: 'hello 你好 😀' appears in both editors.
  C. /hotkeys derives from the same registry on both sides: the remapped
     'shift+ctrl+m' row is listed for model cycling and the default ctrl+p
     is no longer listed for that action.
  D. Cursor evidence (IP-003): exactly one inverse cursor cell in the
     focused editor frame on each side (no double cursor / white block).
  E. Both sides quit cleanly via /quit.

Evidence: docs/pi-batch3-evidence/keybindings-<side>-round<n>.json +
herdr-keybindings-parity-summary.json.

Requires HERDR_ENV=1.

Usage: python3 herdr-keybindings-parity.py [--runs 3] [--keep-panes]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

REPO = subprocess.run(
    ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
).stdout.strip()
PI_TEST = os.path.join(REPO, "vendors", "pi", "pi-test.sh")
ADOU_BIN = os.environ.get("ADOU_BIN", os.path.join(REPO, "build", "bin", "adou"))
FIXTURES = os.path.join(REPO, "tests", "e2e", "lib", "pi-oracle", "fixtures")
EVIDENCE = os.path.join(REPO, "docs", "pi-batch3-evidence")
ORACLE_COMMIT = "cced6a21da273b26ee4a23a803680614bbe8dd1e"

REMAPPED_ROW_RE = re.compile(r"shift\+ctrl\+m.*[Cc]ycle to next model")
CTRL_P_CYCLE_RE = re.compile(r"ctrl\+p.*[Cc]ycle to next model")
INVERSE_CELL_RE = re.compile(r"\x1b\[7m \x1b\[27m")


def herdr(*args: str) -> dict:
    result = subprocess.run(["herdr", *args], capture_output=True, text=True, check=True)
    stdout = (result.stdout or "").strip()
    if not stdout:
        return {}
    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        return {"plain": stdout}


def pane_read_raw(pane: str) -> str:
    # ANSI snapshot: the inverse cursor cell is the IP-003 evidence.
    result = subprocess.run(
        ["herdr", "pane", "read", pane, "--source", "visible", "--format", "ansi"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout or ""


def pane_read(pane: str) -> str:
    result = subprocess.run(
        ["herdr", "pane", "read", pane, "--source", "visible", "--format", "text"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout or ""


def sanitize(text: str, run_root: str) -> str:
    for marker in (run_root, REPO):
        if marker:
            text = text.replace(marker, "<run>")
    for name in (os.environ.get("USER") or "", os.environ.get("LOGNAME") or ""):
        if name:
            text = text.replace(name, "<user>")
    return text


def send_keys(pane: str, *keys: str) -> None:
    herdr("pane", "send-keys", pane, *keys)


def send_text(pane: str, text: str) -> None:
    herdr("pane", "send-text", pane, text)


def wait_fragment(pane: str, fragment: str, timeout: float) -> str:
    deadline = time.time() + timeout
    snapshot = ""
    while time.time() < deadline:
        snapshot = pane_read(pane)
        if fragment in snapshot:
            return snapshot
        time.sleep(0.5)
    raise TimeoutError(f"fragment {fragment!r} not seen in pane {pane} within {timeout}s")


def launch_side(side: str, run_root: str, panes: list[str]) -> tuple[str, str]:
    home = os.path.join(run_root, "home")
    cwd = os.path.join(run_root, "cwd")
    shutil.copytree(os.path.join(FIXTURES, "batch1", "home"), home, dirs_exist_ok=True)
    shutil.copytree(os.path.join(FIXTURES, "cwd"), cwd, dirs_exist_ok=True)
    agent = os.path.join(home, ".pi", "agent")
    open(os.path.join(agent, ".adou-setup"), "w").close()
    with open(os.path.join(agent, "keybindings.json"), "w") as raw:
        json.dump({"app.model.cycleForward": "shift+ctrl+m"}, raw)
    env = [
        f"HOME={home}",
        f"PI_CODING_AGENT_DIR={agent}",
        f"PI_CODING_AGENT_SESSION_DIR={os.path.join(run_root, 'sessions')}",
        "TERM=xterm-256color",
        "LANG=en_US.UTF-8",
        "LC_ALL=en_US.UTF-8",
        "LC_CTYPE=en_US.UTF-8",
        "DEEPSEEK_API_KEY=test-key",
    ]
    split = herdr(
        "pane", "split", "--current", "--direction", "right", "--cwd", cwd,
        "--no-focus", *[item for pair in (("--env", item) for item in env) for item in pair],
    )
    pane = split["result"]["pane"]["pane_id"]
    panes.append(pane)
    if side == "pi":
        command = (
            f"{PI_TEST} --no-env --offline --approve --no-session --no-context-files "
            "--provider deepseek --model deepseek/deepseek-v4-flash --thinking off"
        )
        ready = "v0.82.1"
    else:
        command = (
            f"{ADOU_BIN} --offline --no-context-files --no-session "
            "--provider deepseek --model deepseek-v4-flash"
        )
        ready = "deepseek-v4-flash"
    herdr("pane", "run", pane, command)
    wait_fragment(pane, ready, 240.0)
    time.sleep(4.0)
    return pane, home


def drive_side(side: str, pane: str, home: str) -> dict:
    run_root = os.path.dirname(home)
    record: dict = {
        "side": side,
        "pane": pane,
        "milestones": {},
        "header_hint": False,
        "typed_text": False,
        "hotkeys_remapped": False,
        "hotkeys_default_gone": False,
        "inverse_cursor_cells": -1,
        "quit_confirmed": False,
    }
    # A. Startup header hint line.
    startup = pane_read(pane)
    record["milestones"]["startup"] = sanitize(startup, run_root)
    record["header_hint"] = (
        "interrupt" in startup and "clear/exit" in startup and "commands" in startup and "bash" in startup
    )

    # B. Input matrix: ASCII + CJK + emoji in the editor.
    send_text(pane, "hello \u4f60\u597d \U0001F600")
    typed = wait_fragment(pane, "\u4f60\u597d", 20.0)
    record["milestones"]["typed"] = sanitize(typed, run_root)
    record["typed_text"] = "hello" in typed and "\u4f60\u597d" in typed and "\U0001F600" in typed

    # C. /hotkeys derives from the registry: the remap appears, the default
    # model-cycle key does not.  Clear the typed matrix first so the editor
    # holds exactly the /hotkeys command line.
    send_keys(pane, "ctrl+c")
    time.sleep(0.8)
    send_text(pane, "/hotkeys")
    send_keys(pane, "enter")
    if side == "pi":
        # Pi renders /hotkeys as a chat message; the full table lives in the
        # pane scrollback (recent-unwrapped).
        deadline = time.time() + 30.0
        collected = ""
        while time.time() < deadline:
            result = subprocess.run(
                ["herdr", "pane", "read", pane, "--source", "recent-unwrapped",
                 "--lines", "400", "--format", "text"],
                capture_output=True, text=True, check=True,
            )
            collected = result.stdout or ""
            if "Cycle models" in collected:
                break
            time.sleep(0.5)
    else:
        # Adou renders /hotkeys as an overlay with a 12-row window: scroll
        # until the model row is on screen.
        wait_fragment(pane, "Keyboard shortcuts", 30.0)
        collected = pane_read(pane)
        for _ in range(60):
            if "Cycle to next model" in collected:
                break
            send_keys(pane, "down")
            time.sleep(0.25)
            collected = pane_read(pane)
    record["milestones"]["hotkeys"] = sanitize(collected, run_root)
    # The cycle row on each side must show the remapped key and must not
    # show a bare ctrl+p (shift+ctrl+p is the untouched backward default).
    cycle_row = ""
    for line in collected.split("\n"):
        if "Cycle to next model" in line or "Cycle models" in line:
            cycle_row = line.lower()
            break
    record["hotkeys_remapped"] = "shift+ctrl+m" in cycle_row
    record["hotkeys_default_gone"] = bool(cycle_row) and not re.search(r"(?<!shift\+)ctrl\+p", cycle_row)
    # D. Cursor evidence (IP-003): exactly one inverse cursor glyph in the
    # editor frame on each side (Pi resets with [0m, Adou with [27m).
    send_keys(pane, "esc")
    time.sleep(0.8)
    ansi_snapshot = pane_read_raw(pane)
    # Both sides normalize to '\x1b[7m <glyph> \x1b[0m' in the pane capture
    # (the renderer's line reset turns the trailing [27m into [0m).
    record["inverse_cursor_cells"] = len(re.findall(r"\x1b\[7m[^\x1b]*\x1b\[0m", ansi_snapshot))

    # E. Quit cleanly.
    send_text(pane, "/quit")
    send_keys(pane, "enter")
    deadline = time.time() + 20.0
    while time.time() < deadline:
        time.sleep(1.0)
        if pane_read(pane).strip().endswith("%"):
            record["quit_confirmed"] = True
            break
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--keep-panes", action="store_true")
    args = parser.parse_args()
    if os.environ.get("HERDR_ENV") != "1":
        print("must run inside a Herdr-managed pane (HERDR_ENV=1)", file=sys.stderr)
        return 2
    if not os.path.exists(PI_TEST):
        print(f"pi oracle not found at {PI_TEST}", file=sys.stderr)
        return 2
    actual_commit = subprocess.run(
        ["git", "-C", os.path.join(REPO, "vendors", "pi"), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if actual_commit != ORACLE_COMMIT:
        print(f"oracle commit mismatch: {actual_commit!r} != {ORACLE_COMMIT!r}", file=sys.stderr)
        return 2
    adou_head = subprocess.run(
        ["git", "-C", REPO, "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    ).stdout.strip()

    os.makedirs(EVIDENCE, exist_ok=True)
    records: list[dict] = []
    panes: list[str] = []
    try:
        for run_number in range(1, args.runs + 1):
            run_root = tempfile.mkdtemp(prefix=f"adou-herdr-kb-{run_number}-")
            try:
                for side in ("pi", "adou"):
                    pane, home = launch_side(side, run_root, panes)
                    print(f"round {run_number}: {side} pane {pane}", flush=True)
                    record = drive_side(side, pane, home)
                    record.update({"run": run_number, "oracle_commit": actual_commit, "adou_head": adou_head})
                    path = os.path.join(EVIDENCE, f"keybindings-{side}-round{run_number}.json")
                    with open(path, "w") as raw:
                        json.dump(record, raw, indent=2, sort_keys=True)
                    records.append(record)
            finally:
                if not args.keep_panes:
                    for pane in panes:
                        try:
                            herdr("pane", "close", pane)
                        except subprocess.CalledProcessError:
                            pass
                    panes = []
                shutil.rmtree(run_root, ignore_errors=True)

        failures: list[str] = []
        for record in records:
            label = f"{record['side']} run {record['run']}"
            if not record["header_hint"]:
                failures.append(f"{label}: header hint line missing")
            if not record["typed_text"]:
                failures.append(f"{label}: typed matrix not rendered")
            if not record["hotkeys_remapped"]:
                failures.append(f"{label}: /hotkeys missing the remapped key")
            if not record["hotkeys_default_gone"]:
                failures.append(f"{label}: /hotkeys still lists ctrl+p for model cycling")
            if record["inverse_cursor_cells"] != 1:
                failures.append(f"{label}: inverse cursor cells = {record['inverse_cursor_cells']}, want 1")
            if not record["quit_confirmed"]:
                failures.append(f"{label}: /quit did not reach the shell prompt")
        leaks = []
        for marker in (REPO, os.environ.get("USER") or "", os.environ.get("HOME") or ""):
            for record in records:
                dump = json.dumps(record, ensure_ascii=False)
                if marker and marker in dump:
                    leaks.append(marker)
        if leaks:
            failures.append(f"leak check failed: {leaks!r}")
        summary = {
            "case": "herdr-keybindings-parity",
            "oracle": "pi-0.82.1",
            "oracle_commit": actual_commit,
            "adou_head": adou_head,
            "runs": args.runs,
            "records": records,
            "failures": failures,
            "verdict": "PASS" if not failures else "FAIL",
            "leak_checked": True,
        }
        summary_path = os.path.join(EVIDENCE, "herdr-keybindings-parity-summary.json")
        with open(summary_path, "w") as raw:
            json.dump(summary, raw, indent=2, sort_keys=True)
        print(f"herdr-keybindings-parity: {summary['verdict']} ({len(failures)} failure(s))", flush=True)
        for failure in failures:
            print(f"  FAIL: {failure}", flush=True)
        print(f"evidence: {os.path.relpath(summary_path, REPO)}", flush=True)
        return 0 if not failures else 1
    finally:
        if not args.keep_panes:
            for pane in panes:
                try:
                    herdr("pane", "close", pane)
                except subprocess.CalledProcessError:
                    pass


if __name__ == "__main__":
    sys.exit(main())
