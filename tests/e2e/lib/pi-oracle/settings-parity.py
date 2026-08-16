#!/usr/bin/env python3
"""Batch 3 settings selector parity: Pi 0.82.1 vs Adou, same-key comparison.

Both sides run under the Batch 0 PtyCase protocol with the SAME fixed env,
SAME 24x100 terminal, SAME fixture home/cwd (copied per run so the repo
fixtures stay untouched) and the SAME key sequence:

  1. /settings opens the selector.
  2. Scroll to the Transport row; Enter cycles auto -> sse on both sides.
  3. Scroll to the Theme row; Enter opens the theme submenu; two downs
     select light; Enter applies it.  Both persist `theme: "light"` to
     <home>/.pi/agent/settings.json.
  4. Esc closes the selector; /quit exits cleanly on both sides.

Parity contract (what the comparator enforces):
  A. The shared non-image setting rows appear in the SAME order on both
     sides (image rows are excluded by design: Pi hides them without
     terminal image support while Adou shows EXCLUDED rows).
  B. The Transport row shows `auto` initially and `sse` after Enter on
     both sides.
  C. Both sides persist theme light and exit 0.

Evidence: docs/pi-batch3-evidence/settings-parity-summary.json plus one
<side>-run<n>.json record per run (normalized screens, extracted labels,
exit codes).

Usage:
  python3 settings-parity.py [--runs 3] [--self-test]
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from pty_protocol import DEFAULT_READY_MARKER, PtyCase, PtyTimeout, fixed_oracle_env  # noqa: E402
from slash_case import evidence_leaks, normalize_text  # noqa: E402

ROWS, COLS = 24, 100
ORACLE_COMMIT = "cced6a21da273b26ee4a23a803680614bbe8dd1e"
ADOU_READY_MARKER = b"\x1b[>1u"

# Pi settings-selector rows, in Pi order.  Image rows are capability-gated on
# the Pi side and EXCLUDED rows on the Adou side, so they never join the
# order comparison; the shared rows must appear in this exact order.
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
THEME_LIGHT_RE = re.compile(r"Theme\s*[:：]?\s*light\b")


def extract_shared_labels(text: str) -> list[str]:
    """Shared labels present in text, in first-appearance order."""
    present: list[tuple[int, str]] = []
    for label in SHARED_LABELS:
        position = text.find(label)
        if position >= 0:
            present.append((position, label))
    present.sort(key=lambda item: item[0])
    return [label for _, label in present]


def labels_in_order(labels: list[str]) -> bool:
    """Every extracted label must follow the Pi order (gaps allowed)."""
    expected = {label: index for index, label in enumerate(SHARED_LABELS)}
    seen = -1
    for label in labels:
        position = expected.get(label)
        if position is None:
            return False
        if position < seen:
            return False
        seen = position
    return True


def transport_value(text: str) -> str | None:
    match = TRANSPORT_RE.search(text)
    return match.group(1) if match else None


def repo_root() -> str:
    return subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
    ).stdout.strip()


def self_test() -> int:
    failures = 0

    def check(name: str, condition: bool) -> None:
        nonlocal failures
        if not condition:
            failures += 1
            print(f"SELF-TEST FAIL: {name}", file=sys.stderr)

    ordered_text = "\n".join(
        f"{label}    value" for label in SHARED_LABELS
    )
    check("full order", extract_shared_labels(ordered_text) == SHARED_LABELS)
    check(
        "full order sorted",
        labels_in_order(extract_shared_labels(ordered_text)),
    )
    reversed_text = "\n".join(
        f"{label}    value" for label in reversed(SHARED_LABELS)
    )
    check(
        "reversed order rejected",
        not labels_in_order(extract_shared_labels(reversed_text)),
    )
    subset = "\n".join(
        f"{label}    value" for label in ("Auto-compact", "Transport", "Theme")
    )
    check("subset in order", labels_in_order(extract_shared_labels(subset)))
    check("transport sse", transport_value("Transport  sse") == "sse")
    check("transport auto adou", transport_value("Transport: auto") == "auto")
    check("transport missing", transport_value("no transport row") is None)
    print("self-test complete", file=sys.stderr)
    return failures


def capture(case: PtyCase, root: str) -> str:
    """Normalized visible-screen snapshot."""
    return normalize_text(case.screen_text(), root)


def wait_fragment(case: PtyCase, fragment: bytes, timeout: float) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            case.drain(quiet=0.15, timeout=2.0)
        except PtyTimeout:
            pass
        if fragment in bytes(case.raw_ansi()):
            return
        time.sleep(0.05)
    raise PtyTimeout(f"fragment {fragment!r} not seen within {timeout}s")


def run_side(
    side: str,
    argv: list[str],
    env: dict[str, str],
    cwd: str,
    home: str,
    ready_marker: bytes,
    first_frame: bytes | None,
    out_dir: str,
    run_number: int,
) -> dict:
    root = repo_root()
    case = PtyCase(argv, env, cwd, rows=ROWS, cols=COLS, ready_marker=ready_marker)
    case.start()
    record = {
        "case": "settings-parity",
        "side": side,
        "run": run_number,
        "rows": ROWS,
        "cols": COLS,
        "milestones": {},
        "labels_open": [],
        "labels_full": [],
        "transport_before": None,
        "transport_after": None,
        "theme_light_applied": False,
        "theme_file_value": None,
        "exit_code": None,
    }
    try:
        case.wait_ready(timeout=60.0)
        # The keyboard-ready marker is emitted before the first frame; wait
        # for the first rendered frame before driving the UI (Pi's tsx cold
        # boot can take tens of seconds).
        if first_frame is not None:
            wait_fragment(case, first_frame, 120.0)

        case.send_sequence(b"/settings\r", per_key=0.01)
        wait_fragment(case, b"Auto-compact", 30.0)
        time.sleep(0.4)
        record["milestones"]["open"] = capture(case, root)
        record["labels_open"] = extract_shared_labels(record["milestones"]["open"])

        # Scroll to the Transport row and cycle it once (Enter).
        for _ in range(40):
            if b"Transport" in case.raw_ansi():
                break
            case.send_bytes(b"\x1b[B")
            time.sleep(0.12)
        time.sleep(0.3)
        record["transport_before"] = transport_value(capture(case, root))
        case.send_bytes(b"\r")
        for _ in range(50):
            record["transport_after"] = transport_value(capture(case, root))
            if record["transport_after"] == "sse":
                break
            time.sleep(0.12)
        record["milestones"]["transport"] = capture(case, root)
        time.sleep(0.3)

        # Scroll to the Theme row, open the submenu, pick light, apply.
        for _ in range(40):
            if b"Theme" in case.raw_ansi():
                break
            case.send_bytes(b"\x1b[B")
            time.sleep(0.12)
        time.sleep(0.3)
        # The full ordered label list needs the accumulated stream AFTER the
        # Theme row was rendered (every row has scrolled through the list).
        record["labels_full"] = extract_shared_labels(normalize_text(case.raw_ansi().decode("utf-8", "replace"), root))
        case.send_bytes(b"\r")
        wait_fragment(case, b"Automatic", 30.0)
        case.send_bytes(b"\x1b[B")
        time.sleep(0.15)
        case.send_bytes(b"\x1b[B")
        time.sleep(0.15)
        case.send_bytes(b"\r")
        time.sleep(0.5)
        record["theme_light_applied"] = bool(THEME_LIGHT_RE.search(capture(case, root)))

        # Escape closes the selector; /quit exits cleanly.
        case.send_bytes(b"\x1b")
        time.sleep(0.4)
        code = case.quit_via_command(b"/quit\r", timeout=10.0)
        if code is None:
            case.close()
            raise PtyTimeout("TUI did not exit after /quit")
        record["exit_code"] = code

        settings_path = os.path.join(home, ".pi", "agent", "settings.json")
        if os.path.exists(settings_path):
            with open(settings_path) as raw:
                record["theme_file_value"] = json.load(raw).get("theme")

        screens_path = os.path.join(out_dir, f"{side}-run{run_number}.screen")
        with open(screens_path, "w") as raw:
            raw.write(normalize_text(case.raw_ansi().decode("utf-8", "replace"), root))
        record["screen_evidence"] = os.path.relpath(screens_path, root)
    finally:
        case.close()
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.runs < 3:
        parser.error("--runs must be >= 3 (three-round gate)")

    root = repo_root()
    pi_root = os.path.join(root, "vendors", "pi")
    pi_test = os.path.join(pi_root, "pi-test.sh")
    if not os.path.exists(pi_test):
        print(f"pi oracle not found at {pi_root}", file=sys.stderr)
        return 2
    actual_commit = subprocess.run(
        ["git", "-C", pi_root, "rev-parse", "HEAD"], capture_output=True, text=True, check=False
    ).stdout.strip()
    if actual_commit != ORACLE_COMMIT:
        print(f"oracle commit mismatch: {actual_commit!r} != {ORACLE_COMMIT!r}", file=sys.stderr)
        return 2

    adou_bin = os.environ.get("ADOU_BIN", os.path.join(root, "build", "bin", "adou"))
    if not os.path.exists(adou_bin):
        print(f"adou binary not found: {adou_bin}", file=sys.stderr)
        return 2
    adou_head = subprocess.run(
        ["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    ).stdout.strip()

    fixtures_base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
    home_fixture = os.path.join(fixtures_base, "home")
    cwd_fixture = os.path.join(fixtures_base, "cwd")
    out_dir = os.path.join(root, "docs", "pi-batch3-evidence")
    os.makedirs(out_dir, exist_ok=True)

    records: list[dict] = []
    for run_number in range(1, args.runs + 1):
        # Per-run copies keep the repo fixtures untouched (theme light is
        # persisted into the agent settings file during the run).
        run_root = tempfile.mkdtemp(prefix=f"adou-settings-parity-{run_number}-")
        try:
            home = os.path.join(run_root, "home")
            cwd = os.path.join(run_root, "cwd")
            shutil.copytree(home_fixture, home)
            shutil.copytree(cwd_fixture, cwd)
            agent = os.path.join(home, ".pi", "agent")
            env = fixed_oracle_env(home, agent_dir=agent)
            env["PI_CODING_AGENT_SESSION_DIR"] = os.path.join(run_root, "sessions")
            open(os.path.join(agent, ".adou-setup"), "w").close()

            pi_argv = [
                pi_test,
                "--no-env",
                "--offline",
                "--approve",
                "--no-session",
                "--no-context-files",
                "--provider",
                "deepseek",
                "--model",
                "deepseek/deepseek-v4-flash",
                "--thinking",
                "off",
            ]
            adou_argv = [
                adou_bin,
                "--offline",
                "--no-context-files",
                "--no-session",
                "--provider",
                "deepseek",
                "--model",
                "deepseek-v4-flash",
            ]
            pi_record = run_side(
                "pi", pi_argv, dict(env), cwd, home, DEFAULT_READY_MARKER, b"v0.82.1", out_dir, run_number
            )
            pi_record["oracle_commit"] = actual_commit
            adou_record = run_side(
                "adou", adou_argv, dict(env), cwd, home, ADOU_READY_MARKER, b"thinking off", out_dir, run_number
            )
            adou_record["adou_head"] = adou_head
            for record in (pi_record, adou_record):
                record_path = os.path.join(out_dir, f"{record['side']}-run{run_number}.json")
                with open(record_path, "w") as raw:
                    json.dump(record, raw, indent=2, sort_keys=True)
                records.append(record)
        finally:
            shutil.rmtree(run_root, ignore_errors=True)

    failures: list[str] = []
    by_side = {"pi": [r for r in records if r["side"] == "pi"], "adou": [r for r in records if r["side"] == "adou"]}
    for side in ("pi", "adou"):
        side_records = by_side[side]
        if len(side_records) != args.runs:
            failures.append(f"{side}: expected {args.runs} records, got {len(side_records)}")
            continue
        for record in side_records:
            if record["exit_code"] != 0:
                failures.append(f"{side} run {record['run']}: exit code {record['exit_code']}")
            if not labels_in_order(record["labels_full"]) or len(record["labels_full"]) < len(SHARED_LABELS):
                failures.append(
                    f"{side} run {record['run']}: full label list out of order or incomplete: {record['labels_full']}"
                )
            if record["transport_before"] != "auto":
                failures.append(f"{side} run {record['run']}: transport before {record['transport_before']!r}, want 'auto'")
            if record["transport_after"] != "sse":
                failures.append(f"{side} run {record['run']}: transport after {record['transport_after']!r}, want 'sse'")
            if record["theme_file_value"] != "light":
                failures.append(f"{side} run {record['run']}: persisted theme {record['theme_file_value']!r}, want 'light'")

    for run_number in range(1, args.runs + 1):
        pi_labels = by_side["pi"][run_number - 1]["labels_full"]
        adou_labels = by_side["adou"][run_number - 1]["labels_full"]
        if pi_labels != adou_labels:
            failures.append(
                f"run {run_number}: label lists differ\n  pi:   {pi_labels}\n  adou: {adou_labels}"
            )

    leaks: list[str] = []
    leak_markers = [
        marker
        for marker in (
            root,
            os.environ.get("USER") or "",
            os.environ.get("LOGNAME") or "",
            os.environ.get("HOME") or "",
        )
        if marker
    ]
    for record in records:
        leaks.extend(evidence_leaks(record, leak_markers))
    if leaks:
        failures.extend(f"leak check failed: {leak!r}" for leak in leaks)

    summary = {
        "case": "settings-parity",
        "oracle": "pi-0.82.1",
        "oracle_commit": actual_commit,
        "adou_head": adou_head,
        "runs": args.runs,
        "records": records,
        "failures": failures,
        "verdict": "PASS" if not failures else "FAIL",
        "leak_checked": True,
    }
    summary_path = os.path.join(out_dir, "settings-parity-summary.json")
    with open(summary_path, "w") as raw:
        json.dump(summary, raw, indent=2, sort_keys=True)
    print(f"settings-parity: {summary['verdict']} ({len(failures)} failure(s))")
    for failure in failures:
        print(f"  FAIL: {failure}")
    print(f"evidence: {os.path.relpath(summary_path, root)}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
