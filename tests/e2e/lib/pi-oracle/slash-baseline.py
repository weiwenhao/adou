#!/usr/bin/env python3
"""Pi 0.82.1 slash `/` baseline under the shared PTY protocol (Batch 0).

Pi-only runner. The former --side switch was removed: it only swapped the
ready marker while still launching Pi, so it could not honestly claim Adou
support. The shared PtyCase (tests/e2e/lib/pty_protocol.py) stays reusable;
the Adou side arrives in a later batch with its own argv mapping.

Acceptance (plan Batch 0, rework; verdict recorded per run and overall):
1. semantic assertions (tests/e2e/lib/pi-oracle/slash_case.py) PASS for
   every run: startup shows Pi 0.82.1 + the three fixture skills + the fixed
   model; slash-open shows input "/", exactly 5 candidates in order
   settings/model/scoped-models/export/import, pager (1/26), model argument
   hint; 40x Up reaches Pi's real wrap state (13/26) with clone selected;
   8x Down reaches (21/26) with reload selected; Esc removes menu and pager,
   keeps "/" input and cursor;
2. every run exits with status 0 (None or non-zero fails);
3. all normalized milestone screens identical across 3 consecutive runs.

Evidence (docs/pi-batch0-evidence/) is machine-independent: local absolute
paths are normalized to <REPO> before storing and hashing. Raw ANSI slices
are never committed; pass --raw-dir <dir> to dump them to a local directory
outside the repo.

Usage:
  python3 slash-baseline.py --runs 3 [--out DIR] [--raw-dir DIR]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from pty_protocol import DEFAULT_READY_MARKER, PtyCase, PtyTimeout, fixed_oracle_env  # noqa: E402
from slash_case import (  # noqa: E402
    MIN_RUNS,
    evidence_leaks,
    normalize_raw_bytes,
    normalize_text,
    validate_record,
    validate_runs,
)

ROWS, COLS = 24, 80
MODEL = "deepseek/deepseek-v4-flash"
ORACLE = "pi-0.82.1"
ORACLE_COMMIT = "cced6a21da273b26ee4a23a803680614bbe8dd1e"

FIXTURE_SKILLS = ("alpha-toolkit", "beta-ops", "gamma-report")
FIXTURE_SETTINGS = {"theme": "dark", "autocompleteMaxVisible": 5}

MILESTONE_KEYS = {
    "slash-open": ["/"],
    "slash-up-wrap": ["\x1b[A"] * 40,
    "slash-down": ["\x1b[B"] * 8,
    "slash-esc-closed": ["\x1b"],
}
QUIT_KEYS = ["\x03", "/", "q", "u", "i", "t", "\r"]


def repo_root() -> str:
    return os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    )


def fixture_paths(root: str) -> dict[str, str]:
    base = os.path.join(root, "tests", "e2e", "lib", "pi-oracle", "fixtures")
    return {
        "home": os.path.join(base, "home"),
        "agent": os.path.join(base, "home", ".pi", "agent"),
        "cwd": os.path.join(base, "cwd"),
    }


def pi_argv(pi_root: str) -> list[str]:
    return [
        os.path.join(pi_root, "pi-test.sh"),
        "--no-env",
        "--offline",
        "--approve",
        "--no-session",
        "--no-context-files",
        "--provider",
        "deepseek",
        "--model",
        MODEL,
        "--thinking",
        "off",
    ]


def oracle_commit(pi_root: str) -> str:
    result = subprocess.run(
        ["git", "-C", pi_root, "rev-parse", "HEAD"], capture_output=True, text=True, check=False
    )
    return result.stdout.strip()


def capture(case: PtyCase, name: str, root: str, quiet: float = 0.5, timeout: float = 12.0) -> tuple[dict, bytes]:
    """Checkpoint the raw boundary, drain, and record the normalized screen.

    The raw hash covers the bytes between consecutive checkpoints AFTER
    bytes-level <REPO> normalization, so it is host-independent. The exact
    raw slice is returned for --raw-dir diagnostics only and is never
    committed.
    """
    case.checkpoint()
    case.drain(quiet=quiet, timeout=timeout)
    raw_slice = case.raw_slice()
    screen = [normalize_text(row, root) for row in case.screen_rows()]
    normalized_raw = normalize_raw_bytes(raw_slice, root)
    milestone = {
        "milestone": name,
        "screen": screen,
        "screen_sha256": hashlib.sha256("\n".join(screen).encode("utf-8")).hexdigest(),
        "cursor": list(case.cursor()),
        "normalized_raw_sha256": hashlib.sha256(normalized_raw).hexdigest(),
        "normalized_raw_bytes": len(normalized_raw),
    }
    return milestone, raw_slice


def run_one(case: PtyCase, root: str) -> tuple[list[dict], list[bytes], int | None, list[str]]:
    milestones: list[dict] = []
    raw_slices: list[bytes] = []
    failures: list[str] = []
    code = None
    try:
        case.wait_ready(timeout=25.0)
        milestone, raw_slice = capture(case, "startup", root)
        milestones.append(milestone)
        raw_slices.append(raw_slice)
        for name, keys in MILESTONE_KEYS.items():
            for key in keys:
                case.send_bytes(key.encode("utf-8") if isinstance(key, str) else key)
            milestone, raw_slice = capture(case, name, root)
            milestones.append(milestone)
            raw_slices.append(raw_slice)
        # Quit: ctrl+c clears the input (Esc only closes the menu and leaves
        # "/"), then type /quit key-by-key so the autocomplete opens (a
        # single-write "/quit\r" hits Enter before the async menu opens and
        # submits the text as a chat message), then Enter applies/submits.
        case.send_bytes(b"\x03")
        case.drain(quiet=0.4, timeout=5.0)
        case.send_sequence(b"/quit")
        case.drain(quiet=0.6, timeout=5.0)
        case.send_bytes(b"\r")
        code = case.wait_exit(timeout=12.0)
    except PtyTimeout as exc:
        failures.append(f"run: {exc}")
        code = None
    finally:
        case.close()
    return milestones, raw_slices, code, failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--out", default=None)
    parser.add_argument("--raw-dir", default=None, help="dump exact raw ANSI slices to a local dir (diagnostics only, never committed)")
    args = parser.parse_args()

    if validate_runs(args.runs):
        parser.error(f"--runs must be >= 3 (three-round gate), got {args.runs}")

    root = repo_root()
    pi_root = os.path.join(root, "vendors", "pi")
    if not os.path.exists(os.path.join(pi_root, "pi-test.sh")):
        print(f"pi oracle not found at {pi_root}", file=sys.stderr)
        return 2
    actual_commit = oracle_commit(pi_root)
    if actual_commit != ORACLE_COMMIT:
        print(f"oracle commit mismatch: {actual_commit!r} != {ORACLE_COMMIT!r}", file=sys.stderr)
        return 2

    out_dir = args.out or os.path.join(root, "docs", "pi-batch0-evidence")
    os.makedirs(out_dir, exist_ok=True)

    fixture = fixture_paths(root)
    env = fixed_oracle_env(fixture["home"], agent_dir=fixture["agent"])
    fixture_norm = {key: normalize_text(value, root) for key, value in fixture.items()}
    username = os.environ.get("USER") or os.environ.get("LOGNAME") or ""

    records: list[dict] = []
    screens_by_milestone: dict[str, list[list[str]]] = {}
    consistency_failures: list[str] = []

    for run in range(1, args.runs + 1):
        case = PtyCase(pi_argv(pi_root), env, fixture["cwd"], rows=ROWS, cols=COLS,
                       ready_marker=DEFAULT_READY_MARKER)
        case.start()
        milestones, raw_slices, code, run_failures = run_one(case, root)
        if run_failures:
            consistency_failures.extend(run_failures)

        record = {
            "case": "slash-open",
            "oracle": ORACLE,
            "oracle_commit": actual_commit,
            "run": run,
            "terminal": {"rows": ROWS, "cols": COLS},
            "precondition": {
                "offline": True,
                "api_keys": "none",
                "home": fixture_norm["home"],
                "agent_dir": fixture_norm["agent"],
                "cwd": fixture_norm["cwd"],
                "skills": list(FIXTURE_SKILLS),
                "model": MODEL,
                "theme": FIXTURE_SETTINGS["theme"],
                "settings": FIXTURE_SETTINGS,
            },
            "keys": {
                name: [k.encode("utf-8").hex() for k in keys]
                for name, keys in MILESTONE_KEYS.items()
            },
            "quit_keys": [k.encode("utf-8").hex() for k in QUIT_KEYS],
            "milestones": milestones,
            "exit_code": code,
        }
        errors = validate_record(record)
        leaks = evidence_leaks(record, [root, username])
        if leaks:
            errors.append(f"evidence leaks local markers: {leaks!r}")
        record["assertions"] = {"verdict": "PASS" if not errors else "FAIL", "failures": errors}
        records.append(record)

        evidence_path = os.path.join(out_dir, f"evidence-pi-{run}.json")
        with open(evidence_path, "w") as fh:
            json.dump(record, fh, indent=2, ensure_ascii=False)
        print(f"run {run}: exit={code} assertions={record['assertions']['verdict']}")

        if args.raw_dir:
            os.makedirs(args.raw_dir, exist_ok=True)
            for milestone, raw_slice in zip(milestones, raw_slices):
                dump_path = os.path.join(args.raw_dir, f"raw-pi-{run}-{milestone['milestone']}.ansi")
                with open(dump_path, "wb") as fh:
                    fh.write(raw_slice)
        for milestone in milestones:
            screens_by_milestone.setdefault(milestone["milestone"], []).append(milestone["screen"])

    # cross-run consistency of normalized screens
    consistency: dict[str, list[dict]] = {}
    for name, screens in screens_by_milestone.items():
        hashes = []
        identical = True
        first = screens[0]
        for run, screen in enumerate(screens, start=1):
            hashes.append({
                "run": run,
                "sha256": hashlib.sha256("\n".join(screen).encode("utf-8")).hexdigest(),
            })
            if screen != first:
                identical = False
                consistency_failures.append(f"milestone {name}: run {run} screen differs from run 1")
        consistency[name] = {"identical": identical, "runs": hashes}

    per_run = [
        {
            "run": r.get("run"),
            "exit_code": r.get("exit_code"),
            "assertions": r.get("assertions"),
        }
        for r in records
    ]
    all_ok = (
        len(records) >= MIN_RUNS
        and all(
            r.get("exit_code") == 0 and r.get("assertions", {}).get("verdict") == "PASS"
            for r in records
        )
        and not consistency_failures
    )
    summary = {
        "case": "slash-open",
        "oracle": ORACLE,
        "oracle_commit": actual_commit,
        "terminal": {"rows": ROWS, "cols": COLS},
        "runs": args.runs,
        "verdict": "PASS" if all_ok else "FAIL",
        "per_run": per_run,
        "consistency": consistency,
        "failures": consistency_failures,
        "evidence_note": (
            "screens/precondition/summary are normalized (<REPO> replaces the "
            "repo root) and hashes are computed over normalized content; "
            "milestone normalized_raw_sha256 covers the bytes between "
            "consecutive checkpoints AFTER bytes-level <REPO> normalization, "
            "so it is host-independent; exact raw ANSI is never committed "
            "(--raw-dir dumps it locally for diagnostics only)."
        ),
    }
    summary_path = os.path.join(out_dir, "summary-pi.json")
    with open(summary_path, "w") as fh:
        json.dump(summary, fh, indent=2, ensure_ascii=False)
    print("summary:", summary_path)

    if not all_ok:
        print("slash baseline FAILED:", file=sys.stderr)
        for failure in consistency_failures:
            print(" -", failure, file=sys.stderr)
        for r in records:
            for failure in r.get("assertions", {}).get("failures", []):
                print(f" - run {r.get('run')}: {failure}", file=sys.stderr)
        return 1
    print(f"slash baseline OK: {args.runs} runs, semantic assertions PASS, "
          f"screens identical, all exit codes 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
