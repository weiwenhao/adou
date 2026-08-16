#!/usr/bin/env python3
"""Batch 3 settings parity driver over Herdr real terminals.

Drives Pi 0.82.1 (vendors/pi) and the built Adou binary through the SAME
key sequence in two freshly created sibling panes with the SAME fixed
environment (per-run copies of the oracle fixtures so the repo stays
untouched), captures visible-screen snapshots at each milestone, extracts
the shared setting labels and the transport/theme values, and writes the
evidence under docs/pi-batch3-evidence/herdr-*/.

Contract (same as settings-parity.py):
  A. shared non-image setting rows appear in the same Pi order on both sides
     (Pi shows real image rows when the terminal supports images; Adou shows
     EXCLUDED rows — both are excluded from the order comparison).
  B. Transport shows `auto` initially and `sse` after Enter on both sides.
  C. Both sides persist `theme: "light"` to <home>/.pi/agent/settings.json
     and exit cleanly (exit path via /quit).

Requires HERDR_ENV=1 (must run inside a Herdr-managed pane).

Usage: python3 herdr-settings-parity.py [--runs 3] [--keep-panes]
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

# Same shared-label contract as settings-parity.py: image rows are excluded
# from the order comparison (Pi shows them only with terminal image support,
# Adou shows EXCLUDED rows).
SHARED_LABELS = [
    "Auto-compact",
    "Skill commands",
    "Show hardware cursor",
    "Editor padding",
    "Output padding",
    "Autocomplete max items",
    "Clear on shrink",
    "Terminal progress",
    "Steering mode",
    "Follow-up mode",
    "Transport",
    "HTTP idle timeout",
    "Hide thinking",
    "Cache miss notices",
    "Collapse changelog",
    "Quiet startup",
    "Install telemetry",
    "Default project trust",
    "Double-escape action",
    "Tree filter mode",
    "Warnings",
    "Thinking level",
    "Theme",
]

TRANSPORT_RE = re.compile(r"Transport\s*[:：]?\s*(sse|websocket|websocket-cached|auto)")


def extract_shared_labels(text: str) -> list[str]:
    present: list[tuple[int, str]] = []
    for label in SHARED_LABELS:
        position = text.find(label)
        if position >= 0:
            present.append((position, label))
    present.sort(key=lambda item: item[0])
    return [label for _, label in present]


def labels_in_order(labels: list[str]) -> bool:
    expected = {label: index for index, label in enumerate(SHARED_LABELS)}
    seen = -1
    for label in labels:
        position = expected.get(label)
        if position is None or position < seen:
            return False
        seen = position
    return True


def transport_value(text: str) -> str | None:
    match = TRANSPORT_RE.search(text)
    return match.group(1) if match else None


def herdr(*args: str) -> dict:
    result = subprocess.run(["herdr", *args], capture_output=True, text=True, check=True)
    stdout = (result.stdout or "").strip()
    if not stdout:
        return {}
    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        return {"plain": stdout}


def pane_read(pane: str) -> str:
    # pane read emits the snapshot as plain text (wait-output is the JSON
    # variant), so capture stdout directly.
    result = subprocess.run(
        ["herdr", "pane", "read", pane, "--source", "visible", "--format", "text"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout or ""


def sanitize(text: str, run_root: str) -> str:
    # Evidence must not leak the repo path, the per-run temp paths, or the
    # user identity (the pane prompt and the command echo contain them).
    for marker in (run_root, REPO):
        if marker:
            text = text.replace(marker, "<run>")
    for name in (os.environ.get("USER") or "", os.environ.get("LOGNAME") or ""):
        if name:
            text = text.replace(name, "<user>")
    host = os.environ.get("HOSTNAME") or ""
    if host:
        text = text.replace(host, "<host>")
    return text


def send_keys(pane: str, *keys: str) -> None:
    herdr("pane", "send-keys", pane, *keys)


def send_text(pane: str, text: str) -> None:
    herdr("pane", "send-text", pane, text)


def close_selector(pane: str, side: str) -> None:
    # Esc walks up one menu level per press (theme submenu -> list ->
    # closed).  No screen verification: with Pi's clearOnShrink default off,
    # the closed selector leaves stale rows on screen by design, so the
    # screen cannot distinguish closed from open.  Closure is verified by
    # the /quit outcome (input truth) at the end of the run.
    for _ in range(3):
        send_keys(pane, "esc")
        time.sleep(0.7)


def wait_fragment(pane: str, fragment: str, timeout: float, visible: bool = True) -> str:
    deadline = time.time() + timeout
    snapshot = ""
    while time.time() < deadline:
        snapshot = pane_read(pane)
        if fragment in snapshot:
            return snapshot
        time.sleep(0.5)
    raise TimeoutError(
        f"fragment {fragment!r} not seen in pane {pane} within {timeout}s\n"
        f"last snapshot:\n{pane_read(pane)[-3000:]}"
    )


def launch_side(side: str, run_root: str, panes: list[str]) -> tuple[str, str]:
    home = os.path.join(run_root, "home")
    cwd = os.path.join(run_root, "cwd")
    shutil.copytree(os.path.join(FIXTURES, "home"), home, dirs_exist_ok=True)
    shutil.copytree(os.path.join(FIXTURES, "cwd"), cwd, dirs_exist_ok=True)
    agent = os.path.join(home, ".pi", "agent")
    open(os.path.join(agent, ".adou-setup"), "w").close()
    env = [
        f"HOME={home}",
        f"PI_CODING_AGENT_DIR={agent}",
        f"PI_CODING_AGENT_SESSION_DIR={os.path.join(run_root, 'sessions')}",
        "TERM=xterm-256color",
        "LANG=en_US.UTF-8",
        "LC_ALL=en_US.UTF-8",
        "LC_CTYPE=en_US.UTF-8",
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
    # The first frame can appear before the input loop attaches (Adou), and
    # Pi's cold boot settles long after the banner; give both sides a settle
    # window before driving keys.
    time.sleep(4.0)
    return pane, home


def drive_side(side: str, pane: str, home: str) -> dict:
    run_root = os.path.dirname(home)
    record: dict = {
        "side": side,
        "pane": pane,
        "milestones": {},
        "labels_open": [],
        "labels_full": [],
        "transport_before": None,
        "transport_after": None,
        "theme_light_applied": False,
        "theme_file_value": None,
        "quit_confirmed": False,
    }
    # M1: open the settings selector.
    send_text(pane, "/settings")
    send_keys(pane, "enter")
    record["milestones"]["open"] = sanitize(wait_fragment(pane, "Auto-compact", 60.0), run_root)
    record["labels_open"] = extract_shared_labels(record["milestones"]["open"])

    # Walk down to Transport (selected), capturing every frame for the full
    # ordered label list.
    walked: list[str] = [record["milestones"]["open"]]
    target = "→ Transport"
    for _ in range(40):
        snapshot = pane_read(pane)
        walked.append(snapshot)
        if target in snapshot:
            break
        send_keys(pane, "down")
        time.sleep(0.35)
    record["milestones"]["transport_row"] = sanitize(walked[-1], run_root)
    record["transport_before"] = transport_value(walked[-1])
    send_keys(pane, "enter")
    for _ in range(40):
        snapshot = pane_read(pane)
        walked.append(snapshot)
        value = transport_value(snapshot)
        if value == "sse":
            record["milestones"]["transport_after"] = sanitize(snapshot, run_root)
            record["transport_after"] = value
            break
        time.sleep(0.4)
    if record["transport_after"] != "sse":
        raise TimeoutError(f"{side}: transport did not cycle to sse")

    # Walk down to Theme (selected), open the submenu, one down to light
    # (both sides pre-select the current theme, dark), Enter applies.
    target = "→ Theme"
    for _ in range(40):
        snapshot = pane_read(pane)
        walked.append(snapshot)
        if target in snapshot:
            break
        send_keys(pane, "down")
        time.sleep(0.35)
    record["milestones"]["theme_row"] = sanitize(walked[-1], run_root)
    send_keys(pane, "enter")
    wait_fragment(pane, "Automatic", 30.0)
    send_keys(pane, "down")
    time.sleep(0.3)
    send_keys(pane, "enter")
    time.sleep(1.2)
    back = pane_read(pane)
    record["labels_full"] = extract_shared_labels("\n".join(walked) + "\n" + back)

    # Close the selector and quit; the shell prints a fresh zsh prompt
    # after the TUI exits, which is the input-truth closure signal.
    close_selector(pane, side)
    send_text(pane, "/quit")
    send_keys(pane, "enter")
    deadline = time.time() + 20.0
    quit_seen = False
    while time.time() < deadline:
        time.sleep(1.0)
        if pane_read(pane).strip().endswith("%"):
            quit_seen = True
            break
    record["quit_confirmed"] = quit_seen

    settings_path = os.path.join(home, ".pi", "agent", "settings.json")
    if os.path.exists(settings_path):
        with open(settings_path) as raw:
            record["theme_file_value"] = json.load(raw).get("theme")
    # The screen may still show stale selector rows (clearOnShrink default
    # off); the persisted file is the authoritative theme check.
    record["theme_light_applied"] = record["theme_file_value"] == "light"
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
            run_root = tempfile.mkdtemp(prefix=f"adou-herdr-parity-{run_number}-")
            try:
                pi_pane, pi_home = launch_side("pi", run_root, panes)
                print(f"round {run_number}: pi pane {pi_pane}", flush=True)
                pi_record = drive_side("pi", pi_pane, pi_home)
                pi_record.update({"oracle_commit": actual_commit, "run": run_number})
                adou_pane, adou_home = launch_side("adou", run_root, panes)
                print(f"round {run_number}: adou pane {adou_pane}", flush=True)
                adou_record = drive_side("adou", adou_pane, adou_home)
                adou_record.update({"adou_head": adou_head, "run": run_number})
                for record in (pi_record, adou_record):
                    record_path = os.path.join(
                        EVIDENCE, f"herdr-{record['side']}-round{run_number}.json"
                    )
                    with open(record_path, "w") as raw:
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
        by_side = {"pi": [], "adou": []}
        for record in records:
            by_side[record["side"]].append(record)
        for side in ("pi", "adou"):
            for record in by_side[side]:
                if not labels_in_order(record["labels_full"]) or len(record["labels_full"]) < len(SHARED_LABELS):
                    failures.append(
                        f"{side} run {record['run']}: labels out of order or incomplete: {record['labels_full']}"
                    )
                if record["transport_before"] != "auto":
                    failures.append(f"{side} run {record['run']}: transport before {record['transport_before']!r}")
                if record["transport_after"] != "sse":
                    failures.append(f"{side} run {record['run']}: transport after {record['transport_after']!r}")
                if record["theme_file_value"] != "light":
                    failures.append(f"{side} run {record['run']}: persisted theme {record['theme_file_value']!r}")
                if not record["quit_confirmed"]:
                    failures.append(f"{side} run {record['run']}: TUI frame still visible after /quit")
        for run_number in range(1, args.runs + 1):
            pi_labels = next(r["labels_full"] for r in by_side["pi"] if r["run"] == run_number)
            adou_labels = next(r["labels_full"] for r in by_side["adou"] if r["run"] == run_number)
            if pi_labels != adou_labels:
                failures.append(
                    f"run {run_number}: label lists differ\n  pi:   {pi_labels}\n  adou: {adou_labels}"
                )
        leaks = []
        for marker in (REPO, os.environ.get("USER") or "", os.environ.get("HOME") or ""):
            for record in records:
                dump = json.dumps(record, ensure_ascii=False)
                if marker and marker in dump:
                    leaks.append(marker)
        if leaks:
            failures.append(f"leak check failed: {leaks!r}")
        summary = {
            "case": "herdr-settings-parity",
            "oracle": "pi-0.82.1",
            "oracle_commit": actual_commit,
            "adou_head": adou_head,
            "runs": args.runs,
            "records": records,
            "failures": failures,
            "verdict": "PASS" if not failures else "FAIL",
            "leak_checked": True,
        }
        summary_path = os.path.join(EVIDENCE, "herdr-settings-parity-summary.json")
        with open(summary_path, "w") as raw:
            json.dump(summary, raw, indent=2, sort_keys=True)
        print(f"herdr-settings-parity: {summary['verdict']} ({len(failures)} failure(s))", flush=True)
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
