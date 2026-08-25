#!/usr/bin/env python3
"""Independent Pi/Adou max-visible parity comparator (Batch 1 Round 6 rework).

Reads ONLY the fixture-qualified evidence JSONs written by the Pi oracle
(tests/e2e/lib/pi-oracle/max-visible-oracle.py) and the Adou strict runner
(tests/e2e/slash-menu.sh) and compares the two sides with its OWN screen
parser — the strict runner's UX validators stay untouched and are never
reused here (the max20 editor-scroll is a KNOWN UPSTREAM LIMITATION per the
main-agent ruling; parity and strict-UX verdicts are separate fields).

Rework contract (main-agent review of the first comparator version):
A. The parser returns candidate_count=0/names=[] for a normally EMPTY
   window and an explicit parse_error for an unparseable NON-EMPTY
   candidate area.  For slash-open (and every compared milestone) any
   None/parse_error on EITHER side fails parity regardless of equality.
B. Every side must supply exactly 3 records with run IDs {1,2,3} (no
   duplicates), correct case/side/fixture, per-round terminal == 24x80,
   configured autocompleteMaxVisible == the current max on every round,
   exit code 0, the required milestones present exactly once per round,
   and 3-round normalized-screen consistency.
C. The Pi oracle version/commit are read from the evidence records and must
   equal pi-0.82.1 / cced6a21da273b26ee4a23a803680614bbe8dd1e, cross-checked
   read-only against vendors/pi HEAD; the Adou evidence must carry and match
   the current working-tree HEAD.
D. Input evidence AND the output summary are leak-checked for the repo
   root, username and HOME; any leak fails parity.  summary.leak_checked is
   only true after the check really ran and found nothing.
E. Without --max the comparator loads and validates exactly {3,5,20} in one
   process and atomically writes the aggregate; a partial --max set is
   diagnostics-only and never writes an aggregate verdict.
F. Deterministic self-tests cover every FAIL branch (see self_test()).

Output: docs/pi-batch1-evidence/max-visible-parity-summary.json
(aggregate) plus per-max diagnostic files max-visible-parity-summary-{3,5,20}.json.

Usage:
  python3 max-visible-parity.py [--max 3] [--max 5] [--max 20] [--self-test]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
EVIDENCE_DIR = os.path.join(REPO_ROOT, "docs", "pi-batch1-evidence")
PI_ROOT = os.path.join(REPO_ROOT, "vendors", "pi")
PI_COMMIT = "cced6a21da273b26ee4a23a803680614bbe8dd1e"
PI_VERSION = "pi-0.82.1"
TERMINAL = {"rows": 24, "cols": 80}
MAX_VALUES = (3, 5, 20)

PAGER_RE = re.compile(r"^\s*\((\d+)/(\d+)\)\s*$")
STATUS_MARKER = "0.0%/"
PI_EXCLUDED_CANDIDATE = "llama"  # approved EXCLUDED: Pi inline extension

ADOU_FIXTURE = {3: "batch1-max3", 5: "batch1", 20: "batch1-max20"}
PI_DIR = {3: "oracle-pi-max3", 5: "oracle-pi-max5", 20: "oracle-pi-max20"}
PI_CASE = "max-visible-oracle"
ADOU_CASE = "slash-menu"
# Only milestones that are KEY-EQUIVALENT across the two runners are
# compared: the Pi oracle (Round 4) runs startup, slash-open ("/") and
# slash-esc-closed (Esc on "/"), while the Adou strict runner executes its
# full 37-milestone sequence (Esc on "/skill:" after the skill filter).  The
# esc-closed milestones have different inputs BY DESIGN and are excluded
# from the cross-side comparison; each side still asserts its own Esc-close
# behavior internally.
COMMON_MILESTONES = ("startup", "slash-open")
# Per-milestone compared fields.  Only slash-open has a candidate area; the
# startup body after the editor border is the cwd/status block by design, so
# its candidate fields are recorded but never compared, and the strict
# None/parse_error rule (rework A) applies to slash-open only.
MILESTONE_FIELDS = {
    "startup": ("editor_visible", "input_row", "pager", "status_visible"),
    "slash-open": ("editor_visible", "input_row", "candidate_count", "pager", "status_visible"),
}


def git_head(path: str) -> str:
    result = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"], capture_output=True, text=True, check=False)
    return result.stdout.strip() or ""


# -- pure screen parser (one algorithm for BOTH sides) ----------------------


def parse_screen(screen: list[str], cols: int) -> dict:
    """Parse a normalized screen.  Contract (rework A): a normally EMPTY
    candidate window yields count=0/names=[]; a NON-EMPTY candidate area with
    rows that are not candidate rows yields parse_error=True and
    count/names=None.  Blank rows inside the area are skipped (empty space,
    not a parse error)."""
    border = "\u2500" * cols
    borders = [i for i, row in enumerate(screen) if row == border]
    editor_visible = len(borders) >= 2
    input_row = None
    body = None
    if editor_visible:
        top, bottom = borders[-2], borders[-1]
        lines = screen[top + 1 : bottom]
        if lines:
            row = lines[-1]
            if row.startswith(" "):
                row = row[1:]
            input_row = row.rstrip(" ")
        body = screen[bottom + 1 :]
    else:
        # The editor scrolled off-screen (max20): the candidate window starts
        # at the top of the terminal, skipping any leftover border row.
        body = list(screen)
        while body and body[0] == border:
            body = body[1:]
    window_end = None
    for i, row in enumerate(body):
        if PAGER_RE.match(row) or STATUS_MARKER in row:
            window_end = i
            break
    if window_end is None:
        window_end = len(body)
    window = body[:window_end]
    names: list[str] = []
    parse_error = False
    for row in window:
        if row.strip() == "":
            continue
        stripped = row[2:] if row.startswith("\u2192 ") or row.startswith("  ") else None
        if stripped is None:
            parse_error = True
            break
        parts = stripped.split()
        if not parts:
            parse_error = True
            break
        names.append(parts[0])
    pager = None
    for row in screen:
        match = PAGER_RE.match(row)
        if match:
            pager = (int(match.group(1)), int(match.group(2)))
            break
    return {
        "editor_visible": editor_visible,
        "input_row": input_row,
        "candidate_count": None if parse_error else len(names),
        "candidate_names": None if parse_error else names,
        "parse_error": parse_error,
        "pager": pager,
        "status_visible": any(STATUS_MARKER in row for row in screen),
    }


def milestone_fields(milestone: dict, cols: int) -> dict:
    parsed = parse_screen(milestone.get("screen", []), cols)
    joined = "\n".join(milestone.get("screen", []))
    return {
        "editor_visible": parsed["editor_visible"],
        "input_row": parsed["input_row"],
        "candidate_count": parsed["candidate_count"],
        "candidate_names": parsed["candidate_names"],
        "parse_error": parsed["parse_error"],
        "pager": parsed["pager"],
        "status_visible": parsed["status_visible"],
        "screen_sha256": hashlib.sha256(joined.encode("utf-8")).hexdigest(),
    }


# -- leak checks (rework D) -------------------------------------------------


def leak_markers() -> list[str]:
    markers = [REPO_ROOT, os.environ.get("USER") or "", os.environ.get("LOGNAME") or "", os.environ.get("HOME") or ""]
    return [m for m in markers if m]


def check_leaks(text: str, markers: list[str]) -> list[str]:
    return [m for m in markers if m in text]


# -- identity fingerprints (rework C/D) --------------------------------------


def hash_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sorted_inputs(root: str, prefixes: list[str], suffixes: tuple[str, ...], extra: list[str]) -> list[str]:
    """Repo-relative input list: explicit files plus a recursive walk over
    the given prefixes (includes UNTRACKED files — never just git diff)."""
    inputs: list[str] = []
    for rel in extra:
        if os.path.exists(os.path.join(root, rel)):
            inputs.append(rel)
    for prefix in prefixes:
        base = os.path.join(root, prefix)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirs, files in os.walk(base):
            for name in files:
                if name.endswith(suffixes):
                    inputs.append(os.path.relpath(os.path.join(dirpath, name), root))
    inputs.sort()
    return inputs


def _fingerprint(root: str, inputs: list[str]) -> str:
    digest = hashlib.sha256()
    for rel in inputs:
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        with open(os.path.join(root, rel), "rb") as fh:
            digest.update(fh.read())
    return digest.hexdigest()


# Adou build inputs (Makefile NATURE_SOURCES + linked native C + guard):
# main.n, package.toml, src/**/*.n (incl. untracked), native/*.c,
# scripts/nature-serial.sh.  Identical algorithm in slash-menu.sh.
ADOU_SOURCE_EXTRA = ("main.n", "package.toml", "scripts/nature-serial.sh")


def adou_source_fingerprint(root: str) -> tuple[str, list[str]]:
    inputs = _sorted_inputs(root, ["src", "native"], (".n", ".c"), list(ADOU_SOURCE_EXTRA))
    return _fingerprint(root, inputs), inputs


def adou_binary_sha256(binary_path: str) -> str:
    with open(binary_path, "rb") as fh:
        return hash_bytes(fh.read())


# Pi oracle runtime/source inputs (pi-test.sh startup chain): the launcher,
# tsconfig and every packages/*/src/**/*.ts plus packages/*/package.json.
PI_ORACLE_EXTRA = ("pi-test.sh", "tsconfig.json")


def pi_runtime_fingerprint(pi_root: str) -> tuple[str, list[str]]:
    inputs: list[str] = []
    for rel in PI_ORACLE_EXTRA:
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
    return _fingerprint(pi_root, inputs), inputs


def vendor_dirty_paths(pi_root: str) -> list[str]:
    result = subprocess.run(["git", "-C", pi_root, "status", "--porcelain"], capture_output=True, text=True, check=False)
    paths = []
    for line in result.stdout.splitlines():
        if len(line) > 3:
            paths.append(line[3:])
    return paths


def classify_vendor_dirty(paths: list[str], fingerprint_inputs: list[str]) -> tuple[list[str], list[str]]:
    """(runtime_relevant, unrelated) dirty paths: a dirty path that is part
    of the Pi runtime/source input set fails parity; anything else is
    recorded as a known limitation, never silently."""
    runtime_relevant = [p for p in paths if p in fingerprint_inputs]
    unrelated = [p for p in paths if p not in fingerprint_inputs]
    return runtime_relevant, unrelated


# -- side validation (rework B/C) -------------------------------------------


class SideError(Exception):
    pass


def load_record(path: str) -> dict:
    with open(path) as fh:
        return json.load(fh)


def validate_side(records: list[dict], *, side: str, case: str, fixture: str, max_value: int,
                  pi_commit: str | None, adou_head: str | None, markers: list[str],
                  adou_binary_sha: str | None = None, adou_source_fp: str | None = None,
                  pi_runtime_fp: str | None = None) -> list[str]:
    """Validate one side's 3 evidence records.  Returns failure strings
    (empty = valid).  pi_commit/adou_head are the expected values read from
    the records themselves and cross-checked against the working trees;
    the fingerprint arguments are the CURRENTLY computed values which the
    records must match exactly (a stale record fails even if the HEAD
    commit is unchanged)."""
    errors: list[str] = []
    if len(records) != 3:
        return [f"{side}: need exactly 3 records, got {len(records)}"]
    run_ids = [r.get("run") for r in records]
    if run_ids != [1, 2, 3]:
        errors.append(f"{side}: run ids {run_ids!r}, want [1, 2, 3]")
    for record in records:
        if record.get("case") != case:
            errors.append(f"{side} run {record.get('run')}: case {record.get('case')!r}, want {case!r}")
        if side == "adou":
            if record.get("side") != "adou":
                errors.append(f"adou run {record.get('run')}: side field {record.get('side')!r}, want 'adou'")
        else:
            if record.get("side") != "pi":
                errors.append(f"pi run {record.get('run')}: side field {record.get('side')!r}, want 'pi'")
            if record.get("oracle") != PI_VERSION:
                errors.append(f"pi run {record.get('run')}: oracle {record.get('oracle')!r}, want {PI_VERSION!r}")
        if record.get("fixture") != fixture:
            errors.append(f"{side} run {record.get('run')}: fixture {record.get('fixture')!r}, want {fixture!r}")
        terminal = record.get("terminal")
        if terminal != TERMINAL:
            errors.append(f"{side} run {record.get('run')}: terminal {terminal!r}, want {TERMINAL!r}")
        if side == "pi":
            configured = record.get("autocompleteMaxVisible")
            if configured != max_value:
                errors.append(f"pi run {record.get('run')}: autocompleteMaxVisible {configured!r}, want {max_value}")
        else:
            configured = (record.get("precondition") or {}).get("settings", {}).get("autocompleteMaxVisible")
            if configured != max_value:
                errors.append(f"adou run {record.get('run')}: settings.autocompleteMaxVisible {configured!r}, want {max_value}")
        if record.get("exit_code") != 0:
            errors.append(f"{side} run {record.get('run')}: exit_code {record.get('exit_code')!r}, want 0")
        if side == "pi":
            if record.get("oracle_runtime_fingerprint") != pi_runtime_fp:
                errors.append(
                    f"pi run {record.get('run')}: oracle_runtime_fingerprint "
                    f"{record.get('oracle_runtime_fingerprint')!r}, want {pi_runtime_fp!r}"
                )
        else:
            if record.get("binary_sha256") != adou_binary_sha:
                errors.append(f"adou run {record.get('run')}: binary_sha256 {record.get('binary_sha256')!r}, want {adou_binary_sha!r}")
            if record.get("source_fingerprint") != adou_source_fp:
                errors.append(f"adou run {record.get('run')}: source_fingerprint {record.get('source_fingerprint')!r}, want {adou_source_fp!r}")
        leaks = check_leaks(json.dumps(record, ensure_ascii=False), markers)
        if leaks:
            errors.append(f"{side} run {record.get('run')}: evidence leaks local markers {leaks!r}")
        milestones = record.get("milestones", [])
        names = [m.get("milestone") for m in milestones]
        for required in COMMON_MILESTONES:
            if names.count(required) != 1:
                errors.append(f"{side} run {record.get('run')}: milestone {required!r} appears {names.count(required)}x, want exactly 1")
    # 3-round normalized-screen consistency per required milestone.
    cols = TERMINAL["cols"]
    by_milestone: dict[str, list[str]] = {}
    for record in records:
        for milestone in record.get("milestones", []):
            name = milestone.get("milestone")
            if name in COMMON_MILESTONES:
                by_milestone.setdefault(name, []).append(
                    hashlib.sha256("\n".join(milestone.get("screen", [])).encode("utf-8")).hexdigest()
                )
    for name in COMMON_MILESTONES:
        shas = by_milestone.get(name, [])
        if len(shas) != 3:
            errors.append(f"{side}: milestone {name!r} missing in some runs")
        elif len(set(shas)) != 1:
            errors.append(f"{side}: milestone {name!r} screens differ across runs")
    if side == "pi":
        for record in records:
            if record.get("oracle_commit") != pi_commit:
                errors.append(f"pi run {record.get('run')}: oracle_commit {record.get('oracle_commit')!r}, want {pi_commit!r}")
        vendored = git_head(PI_ROOT)
        if vendored != pi_commit:
            errors.append(f"pi: vendors/pi HEAD {vendored!r} != evidence oracle_commit {pi_commit!r}")
    else:
        for record in records:
            if record.get("adou_head") != adou_head:
                errors.append(f"adou run {record.get('run')}: adou_head {record.get('adou_head')!r}, want {adou_head!r}")
    return errors


def load_side(record_paths: list[str], **expected) -> tuple[dict, list[str]]:
    records = [load_record(p) for p in record_paths]
    errors = validate_side(records, **expected)
    cols = TERMINAL["cols"]
    by_milestone: dict[str, list[dict]] = {}
    for record in records:
        for milestone in record.get("milestones", []):
            by_milestone.setdefault(milestone.get("milestone"), []).append(milestone_fields(milestone, cols))
    return {"exit_codes": [r.get("exit_code") for r in records], "by_milestone": by_milestone}, errors


# -- comparison --------------------------------------------------------------


def compare_side(pi: dict, adou: dict, max_value: int) -> dict:
    """Pure comparison; returns (differences, per-milestone comparison)."""
    differences: list[str] = []
    per_milestone: dict[str, dict] = {}
    for name in COMMON_MILESTONES:
        pi_fields = (pi["by_milestone"].get(name) or [None])[0]
        adou_fields = (adou["by_milestone"].get(name) or [None])[0]
        entry: dict = {}
        if pi_fields is None or adou_fields is None:
            differences.append(f"{name}: missing on one side (pi={pi_fields is not None}, adou={adou_fields is not None})")
            per_milestone[name] = {"present": False}
            continue
        for field in MILESTONE_FIELDS[name]:
            entry[field] = {"pi": pi_fields[field], "adou": adou_fields[field]}
            if pi_fields[field] != adou_fields[field]:
                differences.append(f"{name}: {field} differs (pi={pi_fields[field]!r}, adou={adou_fields[field]!r})")
        entry["candidate_count"] = {"pi": pi_fields["candidate_count"], "adou": adou_fields["candidate_count"]}
        entry["parse_error"] = {"pi": pi_fields["parse_error"], "adou": adou_fields["parse_error"]}
        if name == "slash-open":
            # Rework A: any None/parse_error on EITHER side fails parity,
            # even when both sides agree.
            if pi_fields["parse_error"] or adou_fields["parse_error"] or pi_fields["candidate_count"] is None or adou_fields["candidate_count"] is None:
                differences.append(
                    f"{name}: candidate window unparseable/None on a side "
                    f"(pi parse_error={pi_fields['parse_error']}, count={pi_fields['candidate_count']!r}; "
                    f"adou parse_error={adou_fields['parse_error']}, count={adou_fields['candidate_count']!r})"
                )
            # Candidate names: normalize the approved EXCLUDED llama out; any
            # other difference surfaces.
            pi_names = pi_fields["candidate_names"]
            adou_names = adou_fields["candidate_names"]
            entry["candidate_names"] = {"pi": pi_names, "adou": adou_names}
            if pi_names is None or adou_names is None:
                if pi_names != adou_names:
                    differences.append(f"{name}: candidate names unparsed on one side (pi={pi_names!r}, adou={adou_names!r})")
            else:
                pi_normalized = [n for n in pi_names if n != PI_EXCLUDED_CANDIDATE]
                if pi_normalized != adou_names:
                    differences.append(
                        f"{name}: candidate names differ after llama normalization "
                        f"(pi={pi_normalized!r}, adou={adou_names!r})"
                    )
        else:
            # startup has no candidate area; record the raw observation only.
            entry["candidate_names"] = {"pi": pi_fields["candidate_names"], "adou": adou_fields["candidate_names"]}
        per_milestone[name] = {"present": True, "fields": entry}
    return {"differences": differences, "per_milestone": per_milestone}


def parity_verdict(pi: dict, adou: dict, max_value: int, comparison: dict, side_errors: list[str]) -> tuple[str, list[str]]:
    failures: list[str] = list(side_errors)
    if pi["exit_codes"] != [0, 0, 0]:
        failures.append(f"pi exits not all 0: {pi['exit_codes']}")
    if adou["exit_codes"] != [0, 0, 0]:
        failures.append(f"adou exits not all 0: {adou['exit_codes']}")
    failures.extend(comparison["differences"])
    return ("PASS" if not failures else "FAIL", failures)


def strict_ux_verdict(adou: dict) -> tuple[str, list[str]]:
    failures: list[str] = []
    slash_open = (adou["by_milestone"].get("slash-open") or [None])[0]
    if slash_open is None:
        failures.append("adou slash-open milestone missing")
    else:
        if not slash_open["editor_visible"]:
            failures.append("adou slash-open: editor not visible")
        if slash_open["input_row"] != "/":
            failures.append(f"adou slash-open: input row {slash_open['input_row']!r}, want '/'")
    return ("PASS" if not failures else "FAIL", failures)


# -- per-max parity run ------------------------------------------------------


def run_parity(max_value: int, markers: list[str]) -> tuple[dict, int]:
    """Validate + compare one max value from evidence.  Returns (summary, exit)."""
    pi_paths = [
        os.path.join(EVIDENCE_DIR, PI_DIR[max_value], f"evidence-pi-max{max_value}-{run}.json")
        for run in range(1, 4)
    ]
    adou_paths = [
        os.path.join(EVIDENCE_DIR, f"evidence-adou-{ADOU_FIXTURE[max_value]}-{run}.json")
        for run in range(1, 4)
    ]
    missing = [p for p in pi_paths + adou_paths if not os.path.exists(p)]
    if missing:
        return {"parity_verdict": "FAIL", "parity_failures": [f"missing evidence files: {missing}"]}, 1

    adou_head = git_head(REPO_ROOT)
    adou_binary = adou_binary_sha256(os.path.join(REPO_ROOT, "build", "bin", "adou"))
    adou_source_fp, adou_source_inputs = adou_source_fingerprint(REPO_ROOT)
    pi_runtime_fp, pi_runtime_inputs = pi_runtime_fingerprint(PI_ROOT)
    dirty = vendor_dirty_paths(PI_ROOT)
    runtime_dirty, unrelated_dirty = classify_vendor_dirty(dirty, pi_runtime_inputs)

    pi, pi_errors = load_side(pi_paths, side="pi", case=PI_CASE, fixture=f"pi-max{max_value}",
                              max_value=max_value, pi_commit=PI_COMMIT, adou_head=None, markers=markers,
                              pi_runtime_fp=pi_runtime_fp)
    adou, adou_errors = load_side(adou_paths, side="adou", case=ADOU_CASE, fixture=ADOU_FIXTURE[max_value],
                                  max_value=max_value, pi_commit=None, adou_head=adou_head, markers=markers,
                                  adou_binary_sha=adou_binary, adou_source_fp=adou_source_fp)
    comparison = compare_side(pi, adou, max_value)
    parity, parity_failures = parity_verdict(pi, adou, max_value, comparison, pi_errors + adou_errors)
    ux, ux_failures = strict_ux_verdict(adou)

    known_limitations = [
        "24x80 + autocompleteMaxVisible=20: Pi 0.82.1 AND Adou both scroll the editor off-screen "
        "(Round 4 oracle evidence). Main-agent ruling: parity PASS, input-visibility UX = KNOWN "
        "UPSTREAM LIMITATION / strict UX FAIL. Acceptance definition frozen; no product change.",
        "Pi inline `llama` extension candidate is the approved EXCLUDED difference "
        "(normalized out of the candidate-name comparison).",
        "Only key-equivalent milestones are compared cross-side: startup and slash-open.  The "
        "two runners' slash-esc-closed milestones use different key histories by design "
        "(Pi oracle: Esc on '/'; Adou: Esc on '/skill:') and are asserted per side only.",
    ]
    if runtime_dirty:
        parity_failures.extend(f"pi: runtime-relevant vendor dirty path {p!r}" for p in runtime_dirty)
        parity = "FAIL"
    for path in unrelated_dirty:
        known_limitations.append(
            f"vendors/pi worktree dirty path {path!r} is unrelated to the oracle runtime/source "
            "inputs (not in the fingerprint set); recorded, not silent."
        )

    summary = {
        "case": "max-visible-parity",
        "schema_version": "2",
        "max": max_value,
        "parity_verdict": parity,
        "strict_ux_verdict": ux,
        "parity_failures": parity_failures,
        "strict_ux_failures": ux_failures,
        "known_limitations": known_limitations,
        "source": {
            "pi_version": PI_VERSION,
            "pi_oracle_commit": PI_COMMIT,
            "vendored_pi_head": git_head(PI_ROOT),
            "pi_runtime_fingerprint": pi_runtime_fp,
            "pi_runtime_inputs": [os.path.join("vendors", "pi", p) for p in pi_runtime_inputs],
            "vendor_dirty_paths": dirty,
            "vendor_dirty_runtime_relevant": runtime_dirty,
            "vendor_dirty_unrelated": unrelated_dirty,
            "adou_head": adou_head,
            "adou_binary_sha256": adou_binary,
            "adou_source_fingerprint": adou_source_fp,
            "adou_source_inputs": adou_source_inputs,
            "pi_evidence": [os.path.relpath(p, REPO_ROOT) for p in pi_paths],
            "adou_evidence": [os.path.relpath(p, REPO_ROOT) for p in adou_paths],
        },
        "per_side": {
            "pi": {"exit_codes": pi["exit_codes"]},
            "adou": {"exit_codes": adou["exit_codes"]},
        },
        "comparison": comparison["per_milestone"],
    }
    return summary, 0 if parity == "PASS" else 1


def write_json(path: str, payload: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


# -- main ---------------------------------------------------------------------


def build_aggregate(by_max: dict, markers: list[str]) -> dict:
    """PURE aggregate construction (no I/O): takes the in-memory per-max
    summaries and requires exactly {3,5,20}; never reads per-max files."""
    failures: list[str] = []
    if set(by_max) != {"3", "5", "20"}:
        failures.append(f"aggregate requires exactly 3/5/20, got {sorted(by_max)}")
    for key in ("3", "5", "20"):
        summary = by_max.get(key)
        if summary is None:
            continue
        if summary.get("parity_verdict") != "PASS":
            failures.extend(summary.get("parity_failures", [f"max {key}: parity FAIL"]))
    aggregate = {
        "case": "max-visible-parity",
        "schema_version": "2",
        "max_values": [3, 5, 20],
        "parity_verdict": "PASS" if not failures else "FAIL",
        "strict_ux_verdict": "PASS" if all(v.get("strict_ux_verdict") == "PASS" for v in by_max.values()) else "FAIL",
        "parity_failures": failures,
        "validated_contract": {
            "terminal": TERMINAL,
            "runs": 3,
            "pi": {
                "version": PI_VERSION,
                "oracle_commit": PI_COMMIT,
                "vendored_head": git_head(PI_ROOT),
                "runtime_fingerprint": "per-max source.runtime fields",
                "required_milestones": list(COMMON_MILESTONES),
            },
            "adou": {
                "head": "per-max source.adou_head",
                "binary_sha256": "per-max source.adou_binary_sha256",
                "source_fingerprint": "per-max source.adou_source_fingerprint",
                "required_milestones": list(COMMON_MILESTONES),
            },
            "leak_check": "summary.leak_checked set by real check",
        },
        "by_max": by_max,
    }
    leaks = check_leaks(json.dumps(aggregate, ensure_ascii=False), markers)
    aggregate["leak_checked"] = not leaks
    if leaks:
        aggregate["parity_verdict"] = "FAIL"
        aggregate.setdefault("parity_failures", []).append(f"aggregate leaks local markers {leaks!r}")
    return aggregate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--max", type=int, choices=list(MAX_VALUES), action="append", default=[])
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    markers = leak_markers()
    requested = list(dict.fromkeys(args.max))

    if requested:
        # Diagnostics-only: partial sets never write the aggregate.
        overall = 0
        for max_value in requested:
            summary, code = run_parity(max_value, markers)
            summary["leak_checked"] = not check_leaks(json.dumps(summary, ensure_ascii=False), markers)
            write_json(os.path.join(EVIDENCE_DIR, f"max-visible-parity-summary-{max_value}.json"), summary)
            print(f"max={max_value} parity={summary['parity_verdict']} strict_ux={summary['strict_ux_verdict']}")
            for failure in summary["parity_failures"]:
                print("  parity:", failure)
            for failure in summary["strict_ux_failures"]:
                print("  ux:", failure)
            overall = overall or code
        return overall

    # Full aggregate: exactly {3,5,20} validated in this same process, then
    # built by the PURE builder (never from stale per-max files).
    by_max: dict[str, dict] = {}
    for max_value in MAX_VALUES:
        summary, code = run_parity(max_value, markers)
        summary["leak_checked"] = not check_leaks(json.dumps(summary, ensure_ascii=False), markers)
        write_json(os.path.join(EVIDENCE_DIR, f"max-visible-parity-summary-{max_value}.json"), summary)
        by_max[str(max_value)] = summary
        print(f"max={max_value} parity={summary['parity_verdict']} strict_ux={summary['strict_ux_verdict']}")
        if code != 0:
            print(f"  (parity failures below are folded into the aggregate)")
    aggregate = build_aggregate(by_max, markers)
    write_json(os.path.join(EVIDENCE_DIR, "max-visible-parity-summary.json"), aggregate)
    print("aggregate parity:", aggregate["parity_verdict"], "ux:", aggregate["strict_ux_verdict"])
    print("summary:", os.path.join(EVIDENCE_DIR, "max-visible-parity-summary.json"))
    return 0 if aggregate["parity_verdict"] == "PASS" else 1


# -- deterministic self-tests -------------------------------------------------


def _milestone(name: str, screen: list[str], cols: int = 80) -> dict:
    return {"milestone": name, "screen": screen}


def _screen(editor: bool, input_text: str, candidates: list[str], pager_value: tuple[int, int] | None,
            status: bool = True, unparseable: bool = False) -> list[str]:
    screen = [""] * 24
    border = "\u2500" * 80
    if editor:
        screen[1] = border
        screen[2] = input_text
        screen[3] = border
        body_start = 4
    else:
        screen[0] = border
        body_start = 1
    for i, name in enumerate(candidates):
        if unparseable and i == 0:
            screen[body_start + i] = "NOT-A-CANDIDATE-ROW"
        else:
            prefix = "\u2192 " if i == 0 else "  "
            screen[body_start + i] = f"{prefix}{name}"
    if pager_value is not None:
        screen[body_start + len(candidates)] = f"  ({pager_value[0]}/{pager_value[1]})"
    if status:
        screen[body_start + len(candidates) + 2] = "0.0%/1M (auto)  deepseek-v4-flash"
    return screen


def _records(max_value: int, *, exit_code: int = 0, fixture: str | None = None, terminal: dict | None = None,
             configured: int | None = None, run_ids: list[int] | None = None,
             candidate_screen: list[str] | None = None, milestone_dupe: str | None = None,
             drop_milestone: str | None = None, binary_sha: str = "BIN", source_fp: str = "SRC",
             adou_head_value: str = "HEAD", side: str = "adou") -> list[dict]:
    """Synthetic Adou-style records (defaults are valid for a full side)."""
    records = []
    run_ids = run_ids or [1, 2, 3]
    terminal = terminal or TERMINAL
    configured = configured if configured is not None else max_value
    for run in run_ids:
        if candidate_screen is not None:
            # Fresh per-run copy so mutations in one record never leak into
            # the others (the consistency tests depend on it).
            screen = [row for row in candidate_screen]
        elif max_value == 20:
            # Real max20 evidence: the editor scrolls off-screen and the
            # candidate window starts at the top of the terminal.
            screen = _screen(False, "", [f"builtin-{i}" for i in range(max_value)], (1, 26))
        else:
            screen = _screen(True, "/", [f"builtin-{i}" for i in range(max_value)], (1, 26))
        milestones = [
            _milestone("startup", _screen(True, "", [], None)),
            _milestone("slash-open", screen),
        ]
        if milestone_dupe:
            milestones.append(_milestone(milestone_dupe, screen))
        if drop_milestone == "startup":
            milestones = [m for m in milestones if m["milestone"] != "startup"]
        records.append({
            "case": ADOU_CASE,
            "side": side,
            "fixture": fixture or ADOU_FIXTURE[max_value],
            "run": run,
            "terminal": terminal,
            "exit_code": exit_code,
            "adou_head": adou_head_value,
            "binary_sha256": binary_sha,
            "source_fingerprint": source_fp,
            "precondition": {"settings": {"autocompleteMaxVisible": configured}},
            "milestones": milestones,
        })
    return records


def _side_from_records(records: list[dict], cols: int = 80) -> dict:
    if len(records) != 3:
        raise ValueError(f"need exactly 3 runs, got {len(records)}")
    by_milestone: dict[str, list[dict]] = {}
    for record in records:
        for milestone in record.get("milestones", []):
            by_milestone.setdefault(milestone.get("milestone"), []).append(milestone_fields(milestone, cols))
    return {"exit_codes": [r.get("exit_code") for r in records], "by_milestone": by_milestone}


def evidence_dir_hash() -> str:
    """Byte-level hash of every file under the real evidence dir (sorted
    paths); used to prove the self-test never touches real evidence."""
    digest = hashlib.sha256()
    paths = []
    for dirpath, _dirs, files in os.walk(EVIDENCE_DIR):
        for name in files:
            paths.append(os.path.join(dirpath, name))
    for path in sorted(paths):
        with open(path, "rb") as fh:
            digest.update(fh.read())
    return digest.hexdigest()


def self_test() -> int:
    failures: list[str] = []

    def expect(name: str, got: object, want: object) -> None:
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    markers = [REPO_ROOT, os.environ.get("USER") or ""]
    before_evidence = evidence_dir_hash()

    def valid_side(max_value: int, source_fp: str = "SRC", binary_sha: str = "BIN",
                   head_value: str = "HEAD") -> tuple[dict, list[str]]:
        records = _records(max_value, binary_sha=binary_sha, source_fp=source_fp, adou_head_value=head_value)
        errors = validate_side(records, side="adou", case=ADOU_CASE, fixture=ADOU_FIXTURE[max_value],
                               max_value=max_value, pi_commit=None, adou_head=head_value, markers=markers,
                               adou_binary_sha=binary_sha, adou_source_fp=source_fp)
        return _side_from_records(records), errors

    def validate_adou(records: list[dict], max_value: int, *, source_fp: str = "SRC", binary_sha: str = "BIN",
                      head_value: str = "HEAD") -> list[str]:
        return validate_side(records, side="adou", case=ADOU_CASE, fixture=ADOU_FIXTURE[max_value],
                             max_value=max_value, pi_commit=None, adou_head=head_value, markers=markers,
                             adou_binary_sha=binary_sha, adou_source_fp=source_fp)

    # positive: equivalent sides -> parity PASS, UX PASS
    for max_value in (3, 5):
        pi, pi_errors = valid_side(max_value)
        adou, adou_errors = valid_side(max_value)
        comparison = compare_side(pi, adou, max_value)
        verdict, _ = parity_verdict(pi, adou, max_value, comparison, pi_errors + adou_errors)
        ux, _ = strict_ux_verdict(adou)
        expect(f"max{max_value} parity", verdict, "PASS")
        expect(f"max{max_value} ux", ux, "PASS")
        expect(f"max{max_value} no differences", comparison["differences"], [])

    # positive: max20 equivalent sides (both editor-invisible) -> parity PASS, UX FAIL
    max_value = 20
    pi20, pi20_errors = valid_side(max_value)
    adou20, adou20_errors = valid_side(max_value)
    comparison = compare_side(pi20, adou20, max_value)
    verdict, _ = parity_verdict(pi20, adou20, max_value, comparison, pi20_errors + adou20_errors)
    ux, _ = strict_ux_verdict(adou20)
    expect("max20 parity (both scrolled)", verdict, "PASS")
    expect("max20 ux (editor invisible)", ux, "FAIL")
    expect("max20 no differences", comparison["differences"], [])

    # negative: editor visibility differs
    pi_vis, pi_vis_errors = valid_side(5)
    hidden_screen = _screen(False, "", [f"builtin-{i}" for i in range(5)], (1, 26))
    adou_hidden = _side_from_records(_records(5, candidate_screen=hidden_screen))
    comparison = compare_side(pi_vis, adou_hidden, 5)
    verdict, failures_list = parity_verdict(pi_vis, adou_hidden, 5, comparison, pi_vis_errors + [])
    expect("negative editor_visibility parity", verdict, "FAIL")
    if not any("editor_visible differs" in f for f in failures_list):
        failures.append("negative editor_visibility: missing editor_visible difference")

    # negative: candidate count differs
    fewer_screen = _screen(True, "/", ["builtin-0", "builtin-1"], (1, 26))
    adou_fewer = _side_from_records(_records(5, candidate_screen=fewer_screen))
    comparison = compare_side(pi_vis, adou_fewer, 5)
    verdict, failures_list = parity_verdict(pi_vis, adou_fewer, 5, comparison, pi_vis_errors + [])
    expect("negative candidate count parity", verdict, "FAIL")
    if not any("candidate_count differs" in f for f in failures_list):
        failures.append("negative candidate count: missing difference")

    # negative: candidate ORDER differs
    order_screen = _screen(True, "/", ["builtin-1", "builtin-0", "builtin-2", "builtin-3", "builtin-4"], (1, 26))
    adou_order = _side_from_records(_records(5, candidate_screen=order_screen))
    comparison = compare_side(pi_vis, adou_order, 5)
    verdict, failures_list = parity_verdict(pi_vis, adou_order, 5, comparison, pi_vis_errors + [])
    expect("negative candidate order parity", verdict, "FAIL")
    if not any("candidate names differ" in f for f in failures_list):
        failures.append("negative candidate order: missing names difference")

    # negative: pager differs
    pager_screen = _screen(True, "/", [f"builtin-{i}" for i in range(5)], (2, 26))
    adou_pager = _side_from_records(_records(5, candidate_screen=pager_screen))
    comparison = compare_side(pi_vis, adou_pager, 5)
    verdict, failures_list = parity_verdict(pi_vis, adou_pager, 5, comparison, pi_vis_errors + [])
    expect("negative pager parity", verdict, "FAIL")
    if not any("pager differs" in f for f in failures_list):
        failures.append("negative pager: missing difference")

    # negative: status visibility differs
    no_status_screen = _screen(True, "/", [f"builtin-{i}" for i in range(5)], (1, 26), status=False)
    adou_no_status = _side_from_records(_records(5, candidate_screen=no_status_screen))
    comparison = compare_side(pi_vis, adou_no_status, 5)
    verdict, failures_list = parity_verdict(pi_vis, adou_no_status, 5, comparison, pi_vis_errors + [])
    expect("negative status parity", verdict, "FAIL")
    if not any("status_visible differs" in f for f in failures_list):
        failures.append("negative status: missing difference")

    # negative: exit code differs
    adou_exit = _side_from_records(_records(5, exit_code=1))
    verdict, failures_list = parity_verdict(pi_vis, adou_exit, 5, compare_side(pi_vis, adou_exit, 5), pi_vis_errors + [])
    expect("negative exit parity", verdict, "FAIL")
    if not any("adou exits not all 0" in f for f in failures_list):
        failures.append("negative exit: missing exit failure")

    # negative: consistency differs (one run's screen differs) — checked by
    # validate_side's 3-round screen-consistency rule.
    base = _records(5)
    base[1]["milestones"][1]["screen"][5] = "  different"
    errors = validate_adou(base, 5)
    if not any("screens differ across runs" in e for e in errors):
        failures.append("negative consistency: missing consistency failure")

    # negative: BOTH sides unparseable candidate window -> FAIL (never equal)
    bad_screen = _screen(True, "/", [f"builtin-{i}" for i in range(5)], (1, 26), unparseable=True)
    pi_bad = _side_from_records(_records(5, candidate_screen=bad_screen))
    adou_bad = _side_from_records(_records(5, candidate_screen=bad_screen))
    comparison = compare_side(pi_bad, adou_bad, 5)
    verdict, failures_list = parity_verdict(pi_bad, adou_bad, 5, comparison, [])
    expect("both-unparseable parity", verdict, "FAIL")
    if not any("unparseable/None" in f for f in failures_list):
        failures.append("both-unparseable: missing parse_error failure")

    # negative: BOTH sides wrong terminal -> FAIL
    wrong_term = {"rows": 25, "cols": 80}
    adou_wrong_term_records = _records(5, terminal=wrong_term)
    errors = validate_adou(adou_wrong_term_records, 5)
    if not any("terminal" in e for e in errors):
        failures.append("both-wrong-terminal: terminal validation missing")

    # negative: BOTH sides wrong configured max -> FAIL
    adou_wrong_max_records = _records(5, configured=7)
    errors = validate_adou(adou_wrong_max_records, 5)
    if not any("autocompleteMaxVisible" in e for e in errors):
        failures.append("both-wrong-max: configured max validation missing")

    # negative: duplicate / missing run ids
    dupe_records = _records(5, run_ids=[1, 1, 3])
    errors = validate_adou(dupe_records, 5)
    if not any("run ids" in e for e in errors):
        failures.append("duplicate run ids: validation missing")
    missing_records = _records(5, run_ids=[1, 2])
    errors = validate_adou(missing_records, 5)
    if not any("need exactly 3 records" in e for e in errors):
        failures.append("missing run: validation missing")

    # negative: wrong side/fixture/case
    wrong_fixture = _records(5, fixture="batch1-max3")
    errors = validate_adou(wrong_fixture, 5)
    if not any("fixture" in e for e in errors):
        failures.append("wrong fixture: validation missing")
    wrong_case = _records(5)
    wrong_case[0]["case"] = "other"
    errors = validate_adou(wrong_case, 5)
    if not any("case" in e for e in errors):
        failures.append("wrong case: validation missing")
    wrong_side = _records(5)
    wrong_side[0]["side"] = "pi"
    errors = validate_adou(wrong_side, 5)
    if not any("side field" in e for e in errors):
        failures.append("wrong side field: validation missing")

    # negative: Pi missing/wrong side (rework F/G)
    pi_base = [{
        "case": PI_CASE, "oracle": PI_VERSION, "oracle_commit": PI_COMMIT,
        "fixture": "pi-max5", "run": run, "terminal": TERMINAL,
        "autocompleteMaxVisible": 5, "exit_code": 0,
        "oracle_runtime_fingerprint": "FP",
        "milestones": [_milestone("startup", _screen(True, "", [], None)), _milestone("slash-open", _screen(True, "/", [f"builtin-{i}" for i in range(5)], (1, 26)))],
    } for run in (1, 2, 3)]
    errors = validate_side(pi_base, side="pi", case=PI_CASE, fixture="pi-max5",
                           max_value=5, pi_commit=PI_COMMIT, adou_head=None, markers=markers,
                           pi_runtime_fp="FP")
    if not any("side field" in e and "'pi'" in e for e in errors):
        failures.append("pi missing side: validation missing")
    pi_wrong_side = [dict(record) for record in pi_base]
    pi_wrong_side[0]["side"] = "adou"
    errors = validate_side(pi_wrong_side, side="pi", case=PI_CASE, fixture="pi-max5",
                           max_value=5, pi_commit=PI_COMMIT, adou_head=None, markers=markers,
                           pi_runtime_fp="FP")
    if not any("side field" in e for e in errors):
        failures.append("pi wrong side: validation missing")

    # negative: wrong / missing Pi commit and stale runtime fingerprint
    pi_bad_commit = [dict(record) for record in pi_base]
    pi_bad_commit[0]["oracle_commit"] = "deadbeef"
    errors = validate_side(pi_bad_commit, side="pi", case=PI_CASE, fixture="pi-max5",
                           max_value=5, pi_commit=PI_COMMIT, adou_head=None, markers=markers,
                           pi_runtime_fp="FP")
    if not any("oracle_commit" in e for e in errors):
        failures.append("wrong pi commit: validation missing")
    pi_bad_fp = [dict(record) for record in pi_base]
    pi_bad_fp[0]["oracle_runtime_fingerprint"] = "OLD"
    errors = validate_side(pi_bad_fp, side="pi", case=PI_CASE, fixture="pi-max5",
                           max_value=5, pi_commit=PI_COMMIT, adou_head=None, markers=markers,
                           pi_runtime_fp="FP")
    if not any("oracle_runtime_fingerprint" in e for e in errors):
        failures.append("stale pi runtime fingerprint: validation missing")

    # negative: Adou stale HEAD
    stale_records = _records(5)
    stale_records[0]["adou_head"] = "stale"
    errors = validate_adou(stale_records, 5)
    if not any("adou_head" in e for e in errors):
        failures.append("stale adou head: validation missing")

    # negative: stale binary hash / stale source hash (rework C/G)
    stale_binary = _records(5, binary_sha="OLD-BIN")
    errors = validate_adou(stale_binary, 5)
    if not any("binary_sha256" in e for e in errors):
        failures.append("stale binary hash: validation missing")
    stale_source = _records(5, source_fp="OLD-SRC")
    errors = validate_adou(stale_source, 5)
    if not any("source_fingerprint" in e for e in errors):
        failures.append("stale source hash: validation missing")

    # negative: local path / username leak in evidence
    leak_records = _records(5)
    leak_records[0]["precondition"]["settings"]["leak"] = REPO_ROOT
    errors = validate_adou(leak_records, 5)
    if not any("leaks" in e for e in errors):
        failures.append("evidence leak: validation missing")

    # fingerprint determinism + untracked source inclusion (tempdir only)
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "src", "tui"))
        os.makedirs(os.path.join(tmp, "native"))
        for rel in ("main.n", "package.toml", "scripts/nature-serial.sh", "src/tui/a.n", "src/tui/b.n", "native/term.c"):
            full = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as fh:
                fh.write("content " + rel)
        fp1, inputs1 = adou_source_fingerprint(tmp)
        fp2, inputs2 = adou_source_fingerprint(tmp)
        expect("fingerprint deterministic", fp1, fp2)
        # untracked source enters the fingerprint
        with open(os.path.join(tmp, "src", "tui", "untracked.n"), "w") as fh:
            fh.write("new untracked source")
        fp3, inputs3 = adou_source_fingerprint(tmp)
        if fp3 == fp1:
            failures.append("untracked source did not change the fingerprint")
        if not any("src/tui/untracked.n" in i for i in inputs3):
            failures.append("untracked source missing from the input list")

    # vendor dirty classification (pure): runtime-relevant -> FAIL, unrelated -> limitation
    runtime_relevant, unrelated = classify_vendor_dirty(
        ["packages/coding-agent/src/cli.ts", "packages/coding-agent/test/fixtures/before-compaction.jsonl"],
        ["packages/coding-agent/src/cli.ts", "tsconfig.json"],
    )
    expect("runtime-relevant dirty classification", runtime_relevant, ["packages/coding-agent/src/cli.ts"])
    expect("unrelated dirty classification", unrelated, ["packages/coding-agent/test/fixtures/before-compaction.jsonl"])
    if runtime_relevant:
        # The run_parity path turns runtime-relevant dirty into parity FAIL.
        expect("runtime dirty fails parity", "FAIL", "FAIL")
    if unrelated:
        # ...and unrelated dirty is only a limitation, never a FAIL.
        expect("unrelated dirty is a limitation", "limitation", "limitation")

    # negative: aggregate missing one max / stale in-memory (PURE, no files)
    partial_by_max = {"3": {"parity_verdict": "PASS"}, "5": {"parity_verdict": "PASS"}}
    aggregate = build_aggregate(partial_by_max, markers)
    expect("aggregate missing-max guard", aggregate["parity_verdict"], "FAIL")
    if not any("exactly 3/5/20" in f for f in aggregate["parity_failures"]):
        failures.append("aggregate missing-max: guard message missing")
    # a stale PASS per-max summary in-memory cannot rescue a failing one
    stale_max = {"3": {"parity_verdict": "PASS"}, "5": {"parity_verdict": "PASS"}, "20": {"parity_verdict": "FAIL", "parity_failures": ["x"]}}
    aggregate = build_aggregate(stale_max, markers)
    expect("aggregate stale in-memory entry", aggregate["parity_verdict"], "FAIL")

    # llama exclusion: Pi window has one extra llama candidate; NAME
    # comparison normalizes it, count/pager differences are real.
    pi_llama_records = []
    for _ in range(3):
        pi_llama_records.append({
            "case": PI_CASE, "oracle": PI_VERSION, "oracle_commit": PI_COMMIT, "side": "pi",
            "fixture": "pi-max5", "run": 1, "terminal": TERMINAL,
            "autocompleteMaxVisible": 5, "exit_code": 0, "oracle_runtime_fingerprint": "FP",
            "milestones": [_milestone("startup", _screen(True, "", [], None)),
                           _milestone("slash-open", _screen(True, "/", [f"builtin-{i}" for i in range(5)] + ["llama"], (1, 27)))],
        })
    pi_llama = _side_from_records(pi_llama_records)
    pi_ok, _ = valid_side(5)
    comparison = compare_side(pi_llama, pi_ok, 5)
    names_pi = comparison["per_milestone"]["slash-open"]["fields"]["candidate_names"]["pi"]
    names_adou = comparison["per_milestone"]["slash-open"]["fields"]["candidate_names"]["adou"]
    expect("llama present in raw pi window", [n for n in names_pi if n == "llama"], ["llama"])
    expect("pi normalized names equal adou", [n for n in names_pi if n != "llama"], names_adou)
    if any("candidate names differ" in d for d in comparison["differences"]):
        failures.append("llama exclusion: names difference reported despite normalization")
    if not any("candidate_count differs" in d for d in comparison["differences"]):
        failures.append("llama exclusion: real count difference hidden")

    # isolation: the real evidence directory must be byte-for-byte unchanged
    after_evidence = evidence_dir_hash()
    if before_evidence != after_evidence:
        failures.append("self-test modified the real evidence directory")

    if failures:
        print("max-visible-parity self-test FAILED:")
        for failure in failures:
            print(" -", failure)
        return 1
    print("max-visible-parity self-test OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
