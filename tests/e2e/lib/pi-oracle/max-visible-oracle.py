#!/usr/bin/env python3
"""Pi 0.82.1 max-visible oracle for the Batch 1 autocomplete window contract.

Runs the vendored Pi 0.82.1 (commit cced6a21da273b26ee4a23a803680614bbe8dd1e)
under the exact Batch 0 protocol (PtyCase, fixed env, 24x80, per-key input,
checkpointed milestone slices) for autocompleteMaxVisible = 3, 5 and 20 and
records whether the editor/cursor, the candidate window, the pager and the
status block stay visible.

The strict contract mirrors the Adou runner: the slash input row MUST remain
visible with the candidate window + pager below it.  If Pi itself violates
that (editor scrolled off-screen), the run records a CONTRACT CONFLICT and
exits non-zero so the product side stops instead of redefining acceptance.

Evidence is written to docs/pi-batch1-evidence/oracle-pi-max{N}/ (one
directory per fixture, never overwriting the Adou evidence).

Usage:
  python3 max-visible-oracle.py [--runs 3] [--max 3] [--max 5] [--max 20]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from pty_protocol import DEFAULT_READY_MARKER, PtyCase, PtyTimeout, fixed_oracle_env  # noqa: E402
from slash_case import MIN_RUNS, evidence_leaks, normalize_raw_bytes, normalize_text, validate_runs  # noqa: E402

ROWS, COLS = 24, 80
MODEL = "deepseek/deepseek-v4-flash"
ORACLE_COMMIT = "cced6a21da273b26ee4a23a803680614bbe8dd1e"
PAGER_RE = re.compile(r"^\s*\((\d+)/(\d+)\)\s*$")
BORDER = "\u2500" * COLS
STATUS_MARKERS = ("0.0%/1M", "fixtures/cwd", "deepseek-v4-flash")

# (home_rel, cwd_rel) under the fixtures dir: the Batch 0 layout keeps home
# and cwd as siblings (fixtures/{home,cwd}); the max variants nest them.
FIXTURES = {
    3: ("pi-max3/home", "cwd"),
    5: ("home", "cwd"),
    20: ("pi-max20/home", "cwd"),
}

MILESTONE_KEYS = {
    "slash-open": ["/"],
    "slash-esc-closed": ["\x1b"],
}
QUIT_KEYS = ["\x03", "/", "q", "u", "i", "t", "\r"]


def repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))


# -- identity helpers (identical algorithm to max-visible-parity.py) ---------


def pi_runtime_fingerprint(pi_root: str) -> tuple[str, list[str]]:
    """Deterministic path+content hash of the pi-test.sh startup chain:
    launcher, tsconfig, every packages/*/package.json and every
    packages/*/src/**/*.ts (worktree bytes, sorted, repo-relative)."""
    inputs: list[str] = []
    for rel in ("pi-test.sh", "tsconfig.json"):
        if os.path.exists(os.path.join(pi_root, rel)):
            inputs.append(rel)
    packages = os.path.join(pi_root, "packages")
    if os.path.isdir(packages):
        for name in sorted(os.listdir(packages)):
            pkg = os.path.join(packages, name)
            if not os.path.isdir(pkg):
                continue
            pkg_json = os.path.join(pkg, "package.json")
            if os.path.exists(pkg_json):
                inputs.append(os.path.relpath(pkg_json, pi_root))
            src = os.path.join(pkg, "src")
            if os.path.isdir(src):
                for dirpath, _dirs, files in os.walk(src):
                    for f in files:
                        if f.endswith(".ts"):
                            inputs.append(os.path.relpath(os.path.join(dirpath, f), pi_root))
    inputs.sort()
    digest = hashlib.sha256()
    for rel in inputs:
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        with open(os.path.join(pi_root, rel), "rb") as fh:
            digest.update(fh.read())
    return digest.hexdigest(), inputs


def vendor_dirty_paths(pi_root: str) -> list[str]:
    result = subprocess.run(["git", "-C", pi_root, "status", "--porcelain"], capture_output=True, text=True, check=False)
    paths = []
    for line in result.stdout.splitlines():
        if len(line) > 3:
            paths.append(line[3:])
    return paths


def editor_borders(screen: list[str]) -> tuple[int, int] | None:
    borders = [i for i, row in enumerate(screen) if row == BORDER]
    if len(borders) < 2:
        return None
    return (borders[-2], borders[-1])


def editor_lines(screen: list[str]) -> list[str] | None:
    bounds = editor_borders(screen)
    if bounds is None:
        return None
    return screen[bounds[0] + 1 : bounds[1]]


def input_row(screen: list[str]) -> str | None:
    lines = editor_lines(screen)
    if not lines:
        return None
    row = lines[-1]
    if row.startswith(" "):
        row = row[1:]
    return row.rstrip(" ")


def body_rows(screen: list[str]) -> list[str] | None:
    bounds = editor_borders(screen)
    if bounds is None:
        return None
    return screen[bounds[1] + 1 :]


def candidate_rows(screen: list[str]) -> list[str] | None:
    body = body_rows(screen)
    if body is None:
        return None
    end = None
    for i, row in enumerate(body):
        if PAGER_RE.match(row) or is_status_row(row):
            end = i
            break
    if end is None:
        end = len(body)
    return body[:end]


def pager(screen: list[str]) -> tuple[int, int] | None:
    for row in screen:
        match = PAGER_RE.match(row)
        if match:
            return (int(match.group(1)), int(match.group(2)))
    return None


def is_status_row(row: str) -> bool:
    return any(marker in row for marker in STATUS_MARKERS)


def status_visible(screen: list[str]) -> bool:
    return any(is_status_row(row) for row in screen)


def capture(case: PtyCase, name: str, root: str) -> dict:
    case.checkpoint()
    case.drain(quiet=0.6, timeout=10.0)
    raw_slice = case.raw_slice()
    screen = [normalize_text(row, root) for row in case.screen_rows()]
    return {
        "milestone": name,
        "screen": screen,
        "screen_sha256": hashlib.sha256("\n".join(screen).encode("utf-8")).hexdigest(),
        "cursor": list(case.cursor()),
        "editor_visible": editor_borders(screen) is not None,
        "input_row": input_row(screen),
        "candidate_count": len(candidate_rows(screen)) if candidate_rows(screen) is not None else None,
        "pager": pager(screen),
        "status_visible": status_visible(screen),
        "normalized_raw_sha256": hashlib.sha256(normalize_raw_bytes(raw_slice, root)).hexdigest(),
        "normalized_raw_bytes": len(normalize_raw_bytes(raw_slice, root)),
    }


def run_one(case: PtyCase, root: str) -> tuple[list[dict], int | None, list[str]]:
    milestones: list[dict] = []
    failures: list[str] = []
    code = None
    try:
        case.wait_ready(timeout=25.0)
        milestones.append(capture(case, "startup", root))
        for name, keys in MILESTONE_KEYS.items():
            time.sleep(0.12)
            for key in keys:
                case.send_bytes(key.encode("utf-8") if isinstance(key, str) else key)
            milestones.append(capture(case, name, root))
        for key in QUIT_KEYS:
            case.send_bytes(key.encode("utf-8") if isinstance(key, str) else key)
        code = case.wait_exit(timeout=15.0)
    except PtyTimeout as exc:
        failures.append(f"run: {exc}")
        code = None
    finally:
        case.close()
    return milestones, code, failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--max", type=int, choices=[3, 5, 20], action="append", default=[])
    args = parser.parse_args()
    if validate_runs(args.runs):
        parser.error(f"--runs must be >= {MIN_RUNS} (three-round gate), got {args.runs}")
    max_values = args.max or [3, 5, 20]
    root = repo_root()
    pi_root = os.path.join(root, "vendors", "pi")
    if not os.path.exists(os.path.join(pi_root, "pi-test.sh")):
        print(f"pi oracle not found at {pi_root}", file=sys.stderr)
        return 2
    actual_commit = subprocess.run(
        ["git", "-C", pi_root, "rev-parse", "HEAD"], capture_output=True, text=True, check=False
    ).stdout.strip()
    if actual_commit != ORACLE_COMMIT:
        print(f"oracle commit mismatch: {actual_commit!r} != {ORACLE_COMMIT!r}", file=sys.stderr)
        return 2
    overall_ok = True
    for max_value in max_values:
        home_rel, cwd_rel = FIXTURES[max_value]
        fixtures_base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
        home = os.path.join(fixtures_base, home_rel)
        agent = os.path.join(home, ".pi", "agent")
        cwd = os.path.join(fixtures_base, cwd_rel)
        env = fixed_oracle_env(home, agent_dir=agent)
        argv = [
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
        out_dir = os.path.join(root, "docs", "pi-batch1-evidence", f"oracle-pi-max{max_value}")
        os.makedirs(out_dir, exist_ok=True)
        username = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
        # Identity/fingerprint metadata (Round 6 identity rework): the
        # runtime/source inputs of the pi-test.sh startup chain, the vendored
        # HEAD and the worktree dirty paths are recorded per run so the
        # comparator can cross-check them without guessing constants.
        runtime_fp, runtime_inputs = pi_runtime_fingerprint(pi_root)
        dirty = vendor_dirty_paths(pi_root)
        oracle_meta = {
            "side": "pi",
            "oracle_runtime_fingerprint": runtime_fp,
            "oracle_runtime_inputs": [os.path.join("vendors", "pi", p) for p in runtime_inputs],
            "vendor_dirty_paths": dirty,
        }

        records: list[dict] = []
        screens_by_milestone: dict[str, list[list[str]]] = {}
        consistency_failures: list[str] = []
        for run in range(1, args.runs + 1):
            case = PtyCase(argv, env, cwd, rows=ROWS, cols=COLS, ready_marker=DEFAULT_READY_MARKER)
            case.start()
            milestones, code, run_failures = run_one(case, root)
            if run_failures:
                consistency_failures.extend(run_failures)
            record = {
                "case": "max-visible-oracle",
                "oracle": "pi-0.82.1",
                "oracle_commit": actual_commit,
                "fixture": f"pi-max{max_value}",
                "autocompleteMaxVisible": max_value,
                "run": run,
                "terminal": {"rows": ROWS, "cols": COLS},
                "milestones": milestones,
                "exit_code": code,
            }
            record.update(oracle_meta)
            # Strict contract: the editor/cursor must stay visible with the
            # candidate window + pager + status below it.
            errors: list[str] = []
            if code != 0:
                errors.append(f"exit_code must be 0, got {code!r}")
            by_name = {m.get("milestone"): m for m in milestones}
            for name in ("slash-open", "slash-esc-closed"):
                m = by_name.get(name, {})
                if not m.get("editor_visible"):
                    errors.append(f"{name}: editor scrolled off-screen (editor_visible=false)")
                elif m.get("input_row") != "/":
                    errors.append(f"{name}: input row {m.get('input_row')!r}, want '/'")
            open_m = by_name.get("slash-open", {})
            if open_m.get("candidate_count") != max_value:
                errors.append(
                    f"slash-open: candidate_count {open_m.get('candidate_count')!r}, want {max_value}"
                )
            if open_m.get("pager") != (1, 26):
                errors.append(f"slash-open: pager {open_m.get('pager')!r}, want (1, 26)")
            if not open_m.get("status_visible"):
                errors.append("slash-open: status block scrolled off-screen")
            if not by_name.get("slash-esc-closed", {}).get("status_visible"):
                errors.append("slash-esc-closed: status block scrolled off-screen")
            leaks = evidence_leaks(record, [root, username])
            if leaks:
                errors.append(f"evidence leaks local markers: {leaks!r}")
            record["assertions"] = {"verdict": "PASS" if not errors else "FAIL", "failures": errors}
            records.append(record)
            with open(os.path.join(out_dir, f"evidence-pi-max{max_value}-{run}.json"), "w") as fh:
                json.dump(record, fh, indent=2, ensure_ascii=False)
            print(f"max={max_value} run {run}: exit={code} assertions={record['assertions']['verdict']}")
            for milestone in milestones:
                screens_by_milestone.setdefault(milestone["milestone"], []).append(milestone["screen"])

        consistency: dict[str, dict] = {}
        for name, screens in screens_by_milestone.items():
            identical = all(s == screens[0] for s in screens)
            hashes = [
                {"run": i + 1, "sha256": hashlib.sha256("\n".join(s).encode("utf-8")).hexdigest()}
                for i, s in enumerate(screens)
            ]
            consistency[name] = {"identical": identical, "runs": hashes}
            if not identical:
                consistency_failures.append(f"milestone {name}: screens differ across runs")

        all_ok = (
            len(records) >= MIN_RUNS
            and all(r.get("exit_code") == 0 and r.get("assertions", {}).get("verdict") == "PASS" for r in records)
            and not consistency_failures
        )
        if not all_ok:
            overall_ok = False
        summary = {
            "case": "max-visible-oracle",
            "oracle": "pi-0.82.1",
            "oracle_commit": actual_commit,
            "fixture": f"pi-max{max_value}",
            "autocompleteMaxVisible": max_value,
            "terminal": {"rows": ROWS, "cols": COLS},
            "runs": args.runs,
            "verdict": "PASS" if all_ok else "FAIL",
            "per_run": [{"run": r.get("run"), "exit_code": r.get("exit_code"), "assertions": r.get("assertions")} for r in records],
            "consistency": consistency,
            "failures": consistency_failures,
        }
        with open(os.path.join(out_dir, "summary.json"), "w") as fh:
            json.dump(summary, fh, indent=2, ensure_ascii=False)
        print(f"max={max_value} summary: {summary['verdict']} -> {out_dir}")

    return 0 if overall_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
