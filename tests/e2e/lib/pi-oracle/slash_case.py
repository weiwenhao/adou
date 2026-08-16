#!/usr/bin/env python3
"""Pure semantic validators for the Pi 0.82.1 slash `/` baseline (Batch 0).

The slash case is not accepted by "three runs looked the same": each run's
record must satisfy the semantic contract observed on Pi 0.82.1 (fixed
terminal 24x80, fixture settings/skills/model), and every validator here is a
pure function of the evidence record so it is independently testable.

Validated contract (measured on the vendored Pi 0.82.1 oracle):
- startup: Pi 0.82.1 banner, the three fixture skills, the fixed model;
- slash-open: input line "/", exactly 5 candidate rows in order
  settings/model/scoped-models/export/import, pager (1/26), "→ settings"
  selected, model row carries "<provider/model>" hint and its description;
- 40x Up: Pi's real wrap state (13/26) with "→ clone" selected;
- 8x Down: (21/26) with "→ reload" selected;
- Esc: menu and pager gone, "/" input and cursor (14,1) retained.

Run: python3 slash_case.py  (positive + negative self-tests)
"""

from __future__ import annotations

import re

MILESTONES = ("startup", "slash-open", "slash-up-wrap", "slash-down", "slash-esc-closed")
PAGER_RE = re.compile(r"^\s*\((\d+)/(\d+)\)\s*$")
BORDER = "─" * 80  # fixed terminal width 24x80

EXPECTED_CANDIDATES = ("settings", "model", "scoped-models", "export", "import")
EXPECTED_PAGER_OPEN = (1, 26)
EXPECTED_PAGER_WRAP = (13, 26)
EXPECTED_PAGER_DOWN = (21, 26)
EDITOR_CURSOR = (14, 1)
FIXTURE_SKILLS = ("alpha-toolkit", "beta-ops", "gamma-report")
FIXTURE_MODEL = "deepseek-v4-flash"
ORACLE_VERSION = "pi-0.82.1"

# -- pure screen helpers ----------------------------------------------------


def border_rows(screen: list[str]) -> list[int]:
    return [i for i, row in enumerate(screen) if row == BORDER]


def editor_layout(screen: list[str]) -> tuple[int, int, int] | None:
    """(top_border, input_row, bottom_border) of the editor region."""
    borders = border_rows(screen)
    if len(borders) < 2:
        return None
    top, bottom = borders[-2], borders[-1]
    if bottom - top != 2:
        return None
    return (top, top + 1, bottom)


def input_row(screen: list[str]) -> str | None:
    layout = editor_layout(screen)
    if layout is None:
        return None
    return screen[layout[1]]


def candidate_rows(screen: list[str]) -> list[str] | None:
    """Rows between the editor bottom border and the pager row."""
    layout = editor_layout(screen)
    if layout is None:
        return None
    body = screen[layout[2] + 1 :]
    pager_index = None
    for i, row in enumerate(body):
        if PAGER_RE.match(row):
            pager_index = i
            break
    if pager_index is None:
        return None
    return body[:pager_index]


def candidate_names(screen: list[str]) -> list[str] | None:
    rows = candidate_rows(screen)
    if rows is None:
        return None
    names = []
    for row in rows:
        stripped = row[2:] if row.startswith("→ ") else (row[2:] if row.startswith("  ") else None)
        if stripped is None:
            return None
        parts = stripped.split()
        if not parts:
            return None
        names.append(parts[0])
    return names


# Fixed status-block markers of the slash-open protocol: the rows rendered
# after the editor border with cwd / usage / model info. Rows before the
# first status row (and after the editor bottom border) are the autocomplete
# window (candidates + pager) and must be empty after Esc.
STATUS_MARKERS = ("0.0%/1.0M", "fixtures/cwd", "deepseek-v4-flash")


def is_status_row(row: str) -> bool:
    return any(marker in row for marker in STATUS_MARKERS)


def body_rows(screen: list[str]) -> list[str] | None:
    """Rows after the editor bottom border (candidates/pager/status/footer)."""
    layout = editor_layout(screen)
    if layout is None:
        return None
    return screen[layout[2] + 1 :]


def esc_residue_rows(screen: list[str]) -> list[str] | None:
    """Rows still visible between the editor bottom border and the status
    block. Independent of the pager: a leftover candidate row without a
    pager, or a pager without candidates, both count as residue."""
    body = body_rows(screen)
    if body is None:
        return None
    residue = []
    for row in body:
        if is_status_row(row):
            break
        if row == "":
            continue
        residue.append(row)
    return residue


def pager(screen: list[str]) -> tuple[int, int] | None:
    for row in screen:
        match = PAGER_RE.match(row)
        if match:
            return (int(match.group(1)), int(match.group(2)))
    return None


def selected_name(screen: list[str]) -> str | None:
    for row in screen:
        if row.startswith("→ "):
            parts = row[2:].split()
            return parts[0] if parts else None
    return None


# -- pure semantic validators (each returns a list of failure strings) -------

MIN_RUNS = 3
REPO_MARKER = "<REPO>"


def validate_runs(runs: int) -> list[str]:
    """Three-round gate: fewer than 3 runs can never be accepted."""
    if not isinstance(runs, int) or runs < MIN_RUNS:
        return [f"runs must be >= {MIN_RUNS} (three-round gate), got {runs!r}"]
    return []


def normalize_text(text: str, root: str) -> str:
    """Normalize a local absolute path to the stable <REPO> marker."""
    return text.replace(root, REPO_MARKER)


def normalize_raw_bytes(raw: bytes, root: str) -> bytes:
    """Bytes-level <REPO> normalization of a raw ANSI slice so its hash is
    host-independent. Exact raw may contain the repo root; the normalized
    slice (and therefore the committed hash) never does."""
    return raw.replace(root.encode("utf-8"), REPO_MARKER.encode("utf-8"))


def evidence_leaks(record: dict, markers: list[str]) -> list[str]:
    """Local-path / identity leaks in the serialized evidence record."""
    import json as _json

    dump = _json.dumps(record, ensure_ascii=False)
    return [marker for marker in markers if marker and marker in dump]


def validate_startup(milestone: dict) -> list[str]:
    errors: list[str] = []
    screen = milestone.get("screen")
    if not isinstance(screen, list):
        return ["startup: screen missing"]
    joined = "\n".join(screen)
    if "v0.82.1" not in joined:
        errors.append(f"startup: banner does not show {ORACLE_VERSION}")
    skills_row = [row for row in screen if "alpha-toolkit" in row]
    if not skills_row:
        errors.append("startup: fixture skills not listed")
    else:
        for skill in FIXTURE_SKILLS:
            if skill not in skills_row[0]:
                errors.append(f"startup: fixture skill {skill} missing from skills row")
    model_rows = [row for row in screen if FIXTURE_MODEL in row and "thinking off" in row]
    if not model_rows:
        errors.append(f"startup: status line missing model {FIXTURE_MODEL} / thinking off")
    cwd_rows = [row for row in screen if "fixtures/cwd" in row]
    if not cwd_rows:
        errors.append("startup: fixture cwd not shown in status")
    return errors


def validate_slash_open(milestone: dict) -> list[str]:
    errors: list[str] = []
    screen = milestone.get("screen")
    if not isinstance(screen, list):
        return ["slash-open: screen missing"]
    if input_row(screen) != "/":
        errors.append(f"slash-open: input row is {input_row(screen)!r}, want '/'")
    names = candidate_names(screen)
    if names is None:
        errors.append("slash-open: candidate rows / pager not found")
    elif names != list(EXPECTED_CANDIDATES):
        errors.append(f"slash-open: candidates {names!r}, want {list(EXPECTED_CANDIDATES)!r}")
    if pager(screen) != EXPECTED_PAGER_OPEN:
        errors.append(f"slash-open: pager {pager(screen)!r}, want {EXPECTED_PAGER_OPEN!r}")
    if selected_name(screen) != "settings":
        errors.append(f"slash-open: selected {selected_name(screen)!r}, want 'settings'")
    model_rows = [row for row in screen if "<provider/model>" in row and "Select model (opens selector UI)" in row]
    if not model_rows:
        errors.append("slash-open: model argument hint / description wrong")
    if milestone.get("cursor") != list(EDITOR_CURSOR):
        errors.append(f"slash-open: cursor {milestone.get('cursor')!r}, want {list(EDITOR_CURSOR)!r}")
    return errors


def validate_wrap(milestone: dict) -> list[str]:
    errors: list[str] = []
    screen = milestone.get("screen")
    if not isinstance(screen, list):
        return ["slash-up-wrap: screen missing"]
    if input_row(screen) != "/":
        errors.append(f"slash-up-wrap: input row is {input_row(screen)!r}, want '/'")
    if pager(screen) != EXPECTED_PAGER_WRAP:
        errors.append(f"slash-up-wrap: pager {pager(screen)!r}, want {EXPECTED_PAGER_WRAP!r}")
    if selected_name(screen) != "clone":
        errors.append(f"slash-up-wrap: selected {selected_name(screen)!r}, want 'clone'")
    return errors


def validate_down(milestone: dict) -> list[str]:
    errors: list[str] = []
    screen = milestone.get("screen")
    if not isinstance(screen, list):
        return ["slash-down: screen missing"]
    if input_row(screen) != "/":
        errors.append(f"slash-down: input row is {input_row(screen)!r}, want '/'")
    if pager(screen) != EXPECTED_PAGER_DOWN:
        errors.append(f"slash-down: pager {pager(screen)!r}, want {EXPECTED_PAGER_DOWN!r}")
    if selected_name(screen) != "reload":
        errors.append(f"slash-down: selected {selected_name(screen)!r}, want 'reload'")
    return errors


def validate_esc(milestone: dict) -> list[str]:
    errors: list[str] = []
    screen = milestone.get("screen")
    if not isinstance(screen, list):
        return ["slash-esc-closed: screen missing"]
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"slash-esc-closed: candidate/pager residue after Esc: {residue!r}")
    if input_row(screen) != "/":
        errors.append(f"slash-esc-closed: input row is {input_row(screen)!r}, want '/'")
    if milestone.get("cursor") != list(EDITOR_CURSOR):
        errors.append(f"slash-esc-closed: cursor {milestone.get('cursor')!r}, want {list(EDITOR_CURSOR)!r}")
    return errors


def validate_record(record: dict) -> list[str]:
    """Full semantic validation of one run's evidence record."""
    errors: list[str] = []
    if record.get("exit_code") != 0:
        errors.append(f"exit_code must be 0, got {record.get('exit_code')!r}")
    milestones = record.get("milestones")
    if not isinstance(milestones, list) or len(milestones) != len(MILESTONES):
        count = len(milestones) if isinstance(milestones, list) else "none"
        errors.append(f"expected {len(MILESTONES)} milestones, got {count}")
        return errors
    names = [m.get("milestone") for m in milestones]
    if names != list(MILESTONES):
        errors.append(f"milestone order {names!r}, want {list(MILESTONES)!r}")
    by_name = {m.get("milestone"): m for m in milestones}
    errors.extend(validate_startup(by_name.get("startup", {})))
    errors.extend(validate_slash_open(by_name.get("slash-open", {})))
    errors.extend(validate_wrap(by_name.get("slash-up-wrap", {})))
    errors.extend(validate_down(by_name.get("slash-down", {})))
    errors.extend(validate_esc(by_name.get("slash-esc-closed", {})))
    return errors


def record_verdict(record: dict) -> str:
    return "PASS" if not validate_record(record) else "FAIL"


# -- self-tests --------------------------------------------------------------


def _blank_screen() -> list[str]:
    return [""] * 24


def _screen(startup: bool = False, input_text: str = "/", candidates: list[tuple[str, str]] | None = None,
            pager_value: tuple[int, int] | None = None, selected: str | None = None) -> list[str]:
    screen = _blank_screen()
    screen[1] = " pi v0.82.1"
    screen[2] = " escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash · ctrl+o"
    screen[9] = "[Skills]"
    screen[10] = "  alpha-toolkit, beta-ops, gamma-report"
    screen[13] = BORDER
    screen[14] = input_text
    screen[15] = BORDER
    if candidates is not None:
        for i, (name, description) in enumerate(candidates):
            prefix = "→ " if name == selected else "  "
            screen[16 + i] = f"{prefix}{name:<18s}{description}"
        if pager_value is not None:
            screen[16 + len(candidates)] = f"  ({pager_value[0]}/{pager_value[1]})"
    screen[22] = "0.0%/1.0M (auto)                                deepseek-v4-flash • thinking off"
    screen[23] = "<REPO>/tests/e2e/lib/pi-oracle/fixtures/cwd"
    return screen


def _milestone(name: str, screen: list[str], cursor: tuple[int, int] = (14, 1)) -> dict:
    return {"milestone": name, "screen": screen, "cursor": list(cursor)}


def _valid_record() -> dict:
    open_candidates = [
        ("settings", "Open settings menu"),
        ("model", "<provider/model> — Select model (opens selector UI)"),
        ("scoped-models", "Enable/disable models for Ctrl+P cycling"),
        ("export", "Export session (HTML default, or specify path: .html/.j"),
        ("import", "Import and resume a session from a JSONL file"),
    ]
    wrap_candidates = [
        ("hotkeys", "Show all keyboard shortcuts"),
        ("fork", "Create a new fork from a previous user message"),
        ("clone", "Duplicate the current session at the current position"),
        ("tree", "Navigate session tree (switch branches)"),
        ("trust", "Save project trust decision for future sessions"),
    ]
    down_candidates = [
        ("compact", "Manually compact the session context"),
        ("resume", "Resume a different session"),
        ("reload", "Reload keybindings, extensions, skills, prompts, themes"),
        ("quit", "Quit pi"),
        ("llama", "[t] Manage llama.cpp router models"),
    ]
    return {
        "exit_code": 0,
        "milestones": [
            _milestone("startup", _screen(startup=True)),
            _milestone("slash-open", _screen(candidates=open_candidates, pager_value=(1, 26), selected="settings")),
            _milestone("slash-up-wrap", _screen(candidates=wrap_candidates, pager_value=(13, 26), selected="clone")),
            _milestone("slash-down", _screen(candidates=down_candidates, pager_value=(21, 26), selected="reload")),
            _milestone("slash-esc-closed", _screen()),
        ],
    }


def main() -> int:
    failures: list[str] = []

    def check(name: str, got: object, want: object) -> None:
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    def expect_error(name: str, record: dict, *substrings: str) -> None:
        errors = validate_record(record)
        if not errors:
            failures.append(f"negative {name}: record accepted, expected error")
            return
        joined = "\n".join(errors)
        for substring in substrings:
            if substring not in joined:
                failures.append(f"negative {name}: expected error containing {substring!r}, got: {errors}")

    # positive: the valid record must pass
    check("valid record verdict", record_verdict(_valid_record()), "PASS")

    # negative: non-zero exit
    record = _valid_record()
    record["exit_code"] = 5
    expect_error("non-zero exit", record, "exit_code must be 0")
    record = _valid_record()
    record["exit_code"] = None
    expect_error("None exit", record, "exit_code must be 0")

    # negative: missing milestone / wrong count
    record = _valid_record()
    record["milestones"] = record["milestones"][:4]
    expect_error("missing milestone", record, "expected 5 milestones")

    # negative: wrong candidate count (6 rows)
    record = _valid_record()
    open_milestone = record["milestones"][1]
    screen = open_milestone["screen"]
    screen.insert(21, "  extra                Extra candidate row")
    record["milestones"][1]["screen"] = screen
    expect_error("wrong candidate count", record, "candidates")

    # negative: wrong candidate order (model first, selection stays settings)
    record = _valid_record()
    open_milestone = record["milestones"][1]
    screen = open_milestone["screen"]
    screen[16] = "  model                <provider/model> — Select model (opens selector UI)"
    screen[17] = "→ settings            Open settings menu"
    record["milestones"][1]["screen"] = screen
    expect_error("wrong candidate order", record, "candidates")

    # negative: wrong pager after slash-open
    record = _valid_record()
    record["milestones"][1]["screen"][21] = "  (2/26)"
    expect_error("wrong pager", record, "pager")

    # negative: wrong wrap state (not clone / wrong pager)
    record = _valid_record()
    record["milestones"][2]["screen"][18] = "  clone                Duplicate the current session at the current position"
    record["milestones"][2]["screen"][17] = "→ fork                 Create a new fork from a previous user message"
    expect_error("wrong wrap selection", record, "selected")

    # negative: Esc residue (pager still on screen)
    record = _valid_record()
    record["milestones"][4]["screen"][21] = "  (1/26)"
    expect_error("esc pager residue", record, "residue")

    # negative: Esc candidate residue WITHOUT a pager (false-green repro)
    record = _valid_record()
    record["milestones"][4]["screen"][16] = "  stale                Stale candidate"
    expect_error("esc candidate-only residue", record, "residue")

    # negative: Esc pager-only residue (no candidate rows)
    record = _valid_record()
    record["milestones"][4]["screen"][16] = "  (1/26)"
    expect_error("esc pager-only residue", record, "residue")

    # negative: wrong cursor after Esc
    record = _valid_record()
    record["milestones"][4]["cursor"] = [0, 0]
    expect_error("esc wrong cursor", record, "cursor")

    # runs gate: 0/1/2 must never pass, 3 passes
    check("runs gate 3 ok", validate_runs(3), [])
    for runs in (0, 1, 2):
        errors = validate_runs(runs)
        if not errors:
            failures.append(f"runs gate: {runs} accepted")
        elif "three-round gate" not in "\n".join(errors):
            failures.append(f"runs gate: {runs} error lacks gate text: {errors}")
    check("runs gate non-int rejected", len(validate_runs("3")) > 0, True)

    # normalization: exact raw may contain the local root, normalized must not
    root = "/Users/someone/Code/project"
    exact = b"ESC[2K /Users/someone/Code/project/tests/e2e/lib/pi-oracle/fixtures/cwd (main)"
    normalized = normalize_raw_bytes(exact, root)
    check("normalized raw drops root", normalized, b"ESC[2K <REPO>/tests/e2e/lib/pi-oracle/fixtures/cwd (main)")
    check("normalized raw keeps no root bytes", root.encode("utf-8") in normalized, False)
    check("exact raw keeps root bytes", root.encode("utf-8") in exact, True)
    check("normalized text drops root", normalize_text("/Users/someone/Code/project/a", root), "<REPO>/a")

    # evidence leaks: normalized record must not leak local markers
    clean = {"screen": ["<REPO>/tests/e2e/lib/pi-oracle/fixtures/cwd"], "precondition": {"cwd": "<REPO>/x"}}
    check("clean record no leaks", evidence_leaks(clean, [root, "someone"]), [])
    dirty = {"screen": ["/Users/someone/Code/project/tests/fixtures/cwd"]}
    leaks = evidence_leaks(dirty, [root, "someone"])
    check("dirty record leaks root+user", sorted(leaks), sorted([root, "someone"]))

    if failures:
        print("slash_case self-test FAILED:")
        for failure in failures:
            print(" -", failure)
        return 1
    print("slash_case self-test OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
