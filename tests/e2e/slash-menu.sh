#!/bin/sh
set -eu

# Batch 1 Adou slash-menu runner (pi-interactive-parity-audit-plan.md
# §12.1 B1-R1-13): same shared protocol as the Batch 0 Pi baseline --
# PtyCase (tests/e2e/lib/pty_protocol.py), the VT100/ANSI screen
# interpreter (vt_screen.py) and the exact fixed environment
# (fixed_oracle_env).  Every key is sent individually, every milestone is a
# checkpointed raw slice, and the whole run is covered by pure semantic
# validators.  Three identical runs are required (--runs < 3 is rejected).
#
# Milestones mirror the Pi 0.82.1 protocol (slash-open / slash-up-wrap /
# slash-down / slash-esc-closed) and extend it to the B1-R1 contracts:
# page-key selection stability (B1-R1-06), /skill: metadata tags (B1-R1-07),
# Tab apply without submit (B1-R1-01), Enter argument apply without submit
# (B1-R1-02/03), Ctrl+C and bracketed-paste cancel semantics (B1-R1-05),
# second-line "/" as plain text (B1-R1-04) and /model always entering the
# model selector, never scoped-models (IP-001).
#
# Fixture (tests/e2e/lib/pi-oracle/fixtures/batch1): fixed 24x80 terminal,
# theme dark + autocompleteMaxVisible 5, 2 fixture prompts + 2 fixture
# skills (26 total candidates), deepseek auth fixture, no network, no
# credentials from the parent environment.
#
# Usage: tests/e2e/slash-menu.sh [--runs 3] [--out DIR] [--raw-dir DIR]
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export ADOU_BIN="$binary"
export REPO_ROOT="$repo_root"
python3 - "$@" <<'PY'
#!/usr/bin/env python3
"""Batch 1 Adou slash-menu PTY runner (see the shell header for the protocol
contract).  Pure semantic validators live here; run --self-test to check
them without a PTY."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time

ROOT = os.environ["REPO_ROOT"]
LIB = os.path.join(ROOT, "tests", "e2e", "lib")
sys.path.insert(0, LIB)
sys.path.insert(0, os.path.join(LIB, "pi-oracle"))
from pty_protocol import PtyCase, PtyTimeout, fixed_oracle_env  # noqa: E402
from slash_case import (  # noqa: E402
    MIN_RUNS,
    evidence_leaks,
    normalize_raw_bytes,
    normalize_text,
    validate_runs,
)

ROWS, COLS = 24, 80
MODEL = "deepseek/deepseek-v4-flash"
ADOU_READY = b"\x1b[>1u"
# B1-R4-08: the max-visible variants reuse the same fixture cwd (only the
# agent settings.json differs), so the path/@ completion milestones see the
# same project files while autocompleteMaxVisible 3/20 boundaries are
# asserted per variant.
FIXTURES = {
    "batch1": os.path.join(ROOT, "tests", "e2e", "lib", "pi-oracle", "fixtures", "batch1"),
    "batch1-max3": os.path.join(ROOT, "tests", "e2e", "lib", "pi-oracle", "fixtures", "batch1-max3"),
    "batch1-max20": os.path.join(ROOT, "tests", "e2e", "lib", "pi-oracle", "fixtures", "batch1-max20"),
}
FIXTURE = FIXTURES["batch1"]
HOME = os.path.join(FIXTURE, "home")
AGENT = os.path.join(HOME, ".pi", "agent")
CWD = os.path.join(FIXTURE, "cwd")
MAX_VISIBLE = 5  # parsed from the selected fixture settings.json in main()

TOTAL_CANDIDATES = 26  # 22 builtins + 2 prompts + 2 skills
EXPECTED_OPEN = ("settings", "model", "scoped-models", "export", "import")
EXPECTED_SKILLS = ("skill:alpha-toolkit", "skill:beta-ops")
EXPECTED_PROMPTS = ("code-review", "commit-msg")
EXPECTED_PAGER_OPEN = (1, 26)
EXPECTED_PAGER_WRAP = (13, 26)
EXPECTED_PAGER_DOWN = (21, 26)
STATUS_MARKERS = ("0.0%/1M", "fixtures/batch1/cwd", "deepseek-v4-flash")
# The dark-theme accent SGR that must wrap the WHOLE selected candidate row
# (B1-R1-08 / R4-08 raw assertion).
ACCENT_SGR = "\x1b[38;2;138;190;183m"

PAGER_RE = re.compile(r"^\s*\((\d+)/(\d+)\)\s*$")
BORDER = "\u2500" * COLS


class _ChildDied(Exception):
    """Internal control-flow marker: the child exited mid-run (recorded as
    an honest run failure by run_one, not a runner crash)."""

    def __init__(self, milestone: str):
        super().__init__(milestone)
        self.milestone = milestone

MILESTONE_KEYS = {
    "slash-open": ["/"],
    "slash-up-wrap": ["\x1b[A"] * 40,
    "slash-down": ["\x1b[B"] * 8,
    "slash-page": ["\x1b[6~"],
    "slash-skill-filter": list("skill:"),
    "slash-esc-closed": ["\x1b"],
    "slash-ctrl-c": ["\x03"],
    "slash-tab-reopen": list("/mo") + ["\x1b", "\t"],
    "slash-tab-apply": ["\x03"] + list("/mod") + ["\t"],
    "slash-arg-enter": ["d", "\r"],
    "slash-paste": ["\x03", "\x1b[200~/", "\x1b[201~"],
    "slash-multiline": ["\x03", "x", "\x1b[13;2u", "/"],
    "slash-model-enter": ["\x03"] + list("/model") + ["\r"],
    "slash-model-esc": ["\x1b"],
    # B1-R4-04: me@domain is plain text, never a completion.
    "at-email-literal": list("me@domain"),
    "at-clear-1": ["\x03"],
    # B1-R4-04/08: natural '@' input with candidates OPENS the list (even
    # a single one is never auto-applied).
    "at-one-candidate": list("@co"),
    # Typing shrinks the candidates (requery), Backspace re-expands them.
    "at-type-requery": ["m"],
    "at-backspace-requery": ["\x7f"],
    # Wrap at both edges of the shared SelectList.
    "at-wrap-up": ["\x1b[A"],
    "at-wrap-down": ["\x1b[B"],
    # Active Tab applies the selected item through the shared dispatch.
    "at-active-tab": ["\t"],
    "at-clear-2": ["\x03"],
    # A single directory candidate applies without a trailing space.
    "at-dir-apply": list("@.pi") + ["\t"],
    "at-clear-3": ["\x03"],
    # B1-R4-03: no candidate -> editor untouched (never an indent).
    "at-no-candidate-tab": list("zzzz-no-such-entry") + ["\t"],
    "at-clear-4": ["\x03"],
    # B1-R4-03: blank Tab with a single root candidate applies it directly.
    "at-blank-tab-single": ["\t"],
    "at-clear-5": ["\x03"],
    # Prompt metadata: real descriptions with the [p] source tag.
    "slash-prompt-filter": ["\x03"] + list("/code-r"),
    "at-esc-1": ["\x1b"],
    "at-clear-6": ["\x03"],
    "slash-prompt-filter-2": list("/commit"),
    "at-esc-2": ["\x1b"],
    "at-clear-7": ["\x03"],
    # /login metadata: API-key providers only, openai-codex excluded.
    "slash-login-filter": list("/login deepseek"),
    "at-esc-3": ["\x1b"],
}
QUIT_KEYS = ["\x03"] + list("/quit") + ["\r"]

# Milestone raw-slice assertions: visible_rows() rstrips trailing spaces, so
# contract details that live in the emitted bytes (e.g. the completion
# trailing space of B1-R1-01) are asserted against the checkpointed raw
# slice instead.
RAW_NEEDLES = {
    "slash-tab-apply": [(b"/model ", "completed line carries the trailing space")],
    # B1-R1-08/R4-08: the accent SGR must wrap the whole selected row (the
    # arrow is inside the span).
    "slash-open": [(ACCENT_SGR.encode() + b"\xe2\x86\x92 settings", "selected row carries the accent span")],
}


# -- pure screen helpers ---------------------------------------------------


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
    # The editor renders each line as " " + display (one-cell chrome pad);
    # visible_rows() also rstrips trailing spaces, so the trailing-space
    # contract is asserted on the raw slice instead.
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
        if PAGER_RE.match(row):
            end = i
            break
        if is_status_row(row):
            end = i
            break
    if end is None:
        end = len(body)
    return body[:end]


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


def selected_name(screen: list[str]) -> str | None:
    for row in screen:
        if row.startswith("→ "):
            parts = row[2:].split()
            return parts[0] if parts else None
    return None


def pager(screen: list[str]) -> tuple[int, int] | None:
    for row in screen:
        match = PAGER_RE.match(row)
        if match:
            return (int(match.group(1)), int(match.group(2)))
    return None


def is_status_row(row: str) -> bool:
    return any(marker in row for marker in STATUS_MARKERS)


def esc_residue_rows(screen: list[str]) -> list[str] | None:
    """Rows after the editor bottom border before the status block.  Any
    non-empty row there is a leftover candidate or pager (independent of
    each other, so a pager-only or candidate-only residue also fails)."""
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


def chat_rows(screen: list[str]) -> list[str] | None:
    """Rows above the editor top border (transcript/status area).

    The registry-derived keybinding header line ('... interrupt · ...
    clear/exit · / commands · ! bash · ... more') is static UI chrome, not
    transcript content; the chat-area assertions compare transcript state.
    """
    bounds = editor_borders(screen)
    if bounds is None:
        return None
    rows = screen[: bounds[0]]
    return [row for row in rows if "interrupt \u00b7" not in row]


def editor_empty(screen: list[str]) -> bool:
    lines = editor_lines(screen)
    return bool(lines) and all(line.strip() == "" for line in lines)


# -- pure semantic validators (each returns failure strings) ---------------


def _joined(screen: object, name: str) -> tuple[str, list[str]]:
    if not isinstance(screen, list):
        return "", [f"{name}: screen missing"]
    return "\n".join(screen), []


def validate_startup(milestone: dict) -> list[str]:
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "startup")
    if errors:
        return errors
    if "Welcome to Adou" in joined:
        errors.append("startup: setup overlay must not appear (fixture .adou-setup missing?)")
    cwd_rows = [row for row in screen if "fixtures/batch1/cwd" in row]
    if not cwd_rows:
        errors.append("startup: fixture cwd not shown in status")
    model_rows = [row for row in screen if "deepseek-v4-flash" in row and "thinking off" in row]
    if not model_rows:
        errors.append(f"startup: status line missing model {MODEL} / thinking off")
    return errors


def validate_slash_open(milestone: dict) -> list[str]:
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-open")
    if errors:
        return errors
    if input_row(screen) != "/":
        errors.append(f"slash-open: input row is {input_row(screen)!r}, want '/'")
    rows = candidate_rows(screen)
    names = candidate_names(screen)
    if rows is None or names is None:
        errors.append("slash-open: candidate rows / pager not found")
    elif MAX_VISIBLE == 5:
        if names != list(EXPECTED_OPEN):
            errors.append(f"slash-open: candidates {names!r}, want {list(EXPECTED_OPEN)!r}")
    else:
        # B1-R4-08: the max-visible boundary (3 or 20) limits the window.
        if len(rows) != MAX_VISIBLE:
            errors.append(f"slash-open: {len(rows)} candidate rows, want {MAX_VISIBLE}")
        if names[0] != "settings":
            errors.append(f"slash-open: first candidate {names[0]!r}, want 'settings'")
    if pager(screen) != EXPECTED_PAGER_OPEN:
        errors.append(f"slash-open: pager {pager(screen)!r}, want {EXPECTED_PAGER_OPEN!r}")
    if selected_name(screen) != "settings":
        errors.append(f"slash-open: selected {selected_name(screen)!r}, want 'settings'")
    if "<provider/model>" not in joined or "Select model (opens selector UI)" not in joined:
        errors.append("slash-open: model argument hint / description row missing")
    return errors


def validate_wrap(milestone: dict) -> list[str]:
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-up-wrap")
    if errors:
        return errors
    if input_row(screen) != "/":
        errors.append(f"slash-up-wrap: input row is {input_row(screen)!r}, want '/'")
    if pager(screen) != EXPECTED_PAGER_WRAP:
        errors.append(f"slash-up-wrap: pager {pager(screen)!r}, want {EXPECTED_PAGER_WRAP!r}")
    if selected_name(screen) != "clone":
        errors.append(f"slash-up-wrap: selected {selected_name(screen)!r}, want 'clone'")
    return errors


def validate_down(milestone: dict) -> list[str]:
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-down")
    if errors:
        return errors
    if input_row(screen) != "/":
        errors.append(f"slash-down: input row is {input_row(screen)!r}, want '/'")
    if pager(screen) != EXPECTED_PAGER_DOWN:
        errors.append(f"slash-down: pager {pager(screen)!r}, want {EXPECTED_PAGER_DOWN!r}")
    if selected_name(screen) != "reload":
        errors.append(f"slash-down: selected {selected_name(screen)!r}, want 'reload'")
    return errors


def validate_page(milestone: dict) -> list[str]:
    """B1-R1-06: PageUp/PageDown must leave candidates, selection and pager
    untouched."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-page")
    if errors:
        return errors
    if pager(screen) != EXPECTED_PAGER_DOWN:
        errors.append(f"slash-page: pager changed to {pager(screen)!r}, want {EXPECTED_PAGER_DOWN!r}")
    if selected_name(screen) != "reload":
        errors.append(f"slash-page: selection changed to {selected_name(screen)!r}, want 'reload'")
    return errors


def validate_skill_filter(milestone: dict) -> list[str]:
    """B1-R1-07: dynamic skill items keep their real description and source
    tag; the description must never fall back to a built-in default."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-skill-filter")
    if errors:
        return errors
    names = candidate_names(screen)
    if names != list(EXPECTED_SKILLS):
        errors.append(f"slash-skill-filter: candidates {names!r}, want {list(EXPECTED_SKILLS)!r}")
    rows = candidate_rows(screen)
    if rows is None:
        errors.append("slash-skill-filter: candidate rows not found")
    else:
        for row in rows:
            if "[p]" not in row:
                errors.append(f"slash-skill-filter: missing [p] source tag in {row!r}")
            if "Quit Adou" in row:
                errors.append(f"slash-skill-filter: fallback description on {row!r}")
    return errors


def validate_esc(milestone: dict) -> list[str]:
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-esc-closed")
    if errors:
        return errors
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"slash-esc-closed: candidate/pager residue after Esc: {residue!r}")
    if input_row(screen) != "/skill:":
        errors.append(f"slash-esc-closed: input row is {input_row(screen)!r}, want '/skill:'")
    return errors


def validate_ctrl_c(milestone: dict) -> list[str]:
    """B1-R1-05: Ctrl+C clears the editor and the menu together."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-ctrl-c")
    if errors:
        return errors
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"slash-ctrl-c: candidate/pager residue after Ctrl+C: {residue!r}")
    if not editor_empty(screen):
        errors.append(f"slash-ctrl-c: editor not cleared: {editor_lines(screen)!r}")
    return errors


def validate_cleared(milestone: dict) -> list[str]:
    """Generic Ctrl+C cleanup milestone: editor empty, no menu residue."""
    screen = milestone.get("screen")
    name = milestone.get("milestone", "at-clear")
    joined, errors = _joined(screen, name)
    if errors:
        return errors
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"{name}: candidate/pager residue after Ctrl+C: {residue!r}")
    if not editor_empty(screen):
        errors.append(f"{name}: editor not cleared: {editor_lines(screen)!r}")
    return errors


def validate_esc_only(milestone: dict) -> list[str]:
    """Generic Esc-close milestone: menu closed, input retained."""
    screen = milestone.get("screen")
    name = milestone.get("milestone", "at-esc")
    joined, errors = _joined(screen, name)
    if errors:
        return errors
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"{name}: candidate/pager residue after Esc: {residue!r}")
    return errors


def validate_at_email(milestone: dict) -> list[str]:
    """B1-R4-04: me@domain stays plain text and never opens a completion."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "at-email-literal")
    if errors:
        return errors
    if input_row(screen) != "me@domain":
        errors.append(f"at-email-literal: input row is {input_row(screen)!r}, want 'me@domain'")
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"at-email-literal: email literal must not open a menu: {residue!r}")
    return errors


def validate_at_one(milestone: dict) -> list[str]:
    """B1-R4-04/08: natural '@' input with candidates OPENS the list (even
    a single one is never auto-applied)."""
    screen = milestone.get("screen")
    name = milestone.get("milestone", "at-one-candidate")
    joined, errors = _joined(screen, name)
    if errors:
        return errors
    rows = candidate_rows(screen)
    names = candidate_names(screen)
    if rows is None or names is None:
        errors.append(f"{name}: candidate rows not found (list must open)")
    else:
        if len(names) != 2:
            errors.append(f"{name}: {len(names)} candidates {names!r}, want 2")
        for wanted in ("code-review.md", "commit-msg.md"):
            if wanted not in names:
                errors.append(f"{name}: candidate {wanted!r} missing from {names!r}")
    if input_row(screen) != "@co":
        errors.append(f"{name}: input row is {input_row(screen)!r}, want '@co'")
    return errors


def validate_at_requery(milestone: dict) -> list[str]:
    """B1-R4-08: typing re-queries the candidates; the list narrows."""
    screen = milestone.get("screen")
    name = milestone.get("milestone", "at-type-requery")
    joined, errors = _joined(screen, name)
    if errors:
        return errors
    if input_row(screen) != "@com":
        errors.append(f"{name}: input row is {input_row(screen)!r}, want '@com'")
    names = candidate_names(screen)
    if names != ["commit-msg.md"]:
        errors.append(f"{name}: candidates {names!r}, want ['commit-msg.md']")
    return errors


def validate_at_backspace_requery(milestone: dict) -> list[str]:
    """B1-R4-08: Backspace re-queries and re-expands the candidates."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "at-backspace-requery")
    if errors:
        return errors
    if input_row(screen) != "@co":
        errors.append(f"at-backspace-requery: input row is {input_row(screen)!r}, want '@co'")
    names = candidate_names(screen)
    if names is None or len(names) != 2:
        errors.append(f"at-backspace-requery: candidates {names!r}, want 2")
    return errors


def validate_at_wrap(milestone: dict) -> list[str]:
    """B1-R4-08: the shared SelectList wraps at both edges.  After Up the
    arrow sits on the LAST candidate, after Down back on the FIRST."""
    screen = milestone.get("screen")
    name = milestone.get("milestone", "at-wrap-up")
    joined, errors = _joined(screen, name)
    if errors:
        return errors
    names = candidate_names(screen)
    if names is None or len(names) != 2:
        errors.append(f"{name}: candidates {names!r}, want 2")
        return errors
    selected = selected_name(screen)
    if name == "at-wrap-up":
        want = "commit-msg.md"
    else:
        want = "code-review.md"
    if selected != want:
        errors.append(f"{name}: selected {selected!r}, want {want!r}")
    return errors


def validate_at_active_tab(milestone: dict) -> list[str]:
    """B1-R4-02/12: active Tab applies the selected item through the shared
    dispatch; the inserted value is baseDir-relative (no absolute cwd) and
    the raw slice carries the trailing @file space."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "at-active-tab")
    if errors:
        return errors
    row = input_row(screen)
    if not row or not row.startswith("@.pi/prompts/"):
        errors.append(f"at-active-tab: input row is {row!r}, want a relative '@.pi/prompts/...' value")
    elif os.path.isabs(row[1:]) or "//" in row[1:]:
        errors.append(f"at-active-tab: absolute cwd leaked into the editor: {row!r}")
    elif row != "@.pi/prompts/code-review.md":
        errors.append(
            "at-active-tab: input row is "
            f"{row!r}, want '@.pi/prompts/code-review.md'"
        )
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"at-active-tab: menu residue after Tab: {residue!r}")
    return errors


def validate_at_dir_apply(milestone: dict) -> list[str]:
    """B1-R4-12: a single directory candidate applies WITHOUT a trailing
    space ('@.pi/')."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "at-dir-apply")
    if errors:
        return errors
    if input_row(screen) != "@.pi/":
        errors.append(f"at-dir-apply: input row is {input_row(screen)!r}, want '@.pi/'")
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"at-dir-apply: menu residue after Tab: {residue!r}")
    return errors


def validate_at_no_candidate(milestone: dict) -> list[str]:
    """B1-R4-03: no candidates -> the editor text stays untouched (never an
    indentation)."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "at-no-candidate-tab")
    if errors:
        return errors
    if input_row(screen) != "zzzz-no-such-entry":
        errors.append(f"at-no-candidate-tab: input row is {input_row(screen)!r}, want 'zzzz-no-such-entry'")
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"at-no-candidate-tab: unexpected menu residue: {residue!r}")
    return errors


def validate_at_blank_tab(milestone: dict) -> list[str]:
    """B1-R4-03: blank Tab with a single root candidate ('.pi/') applies it
    directly (Pi 0.82.1 oracle: '.pi/', cursor column 4)."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "at-blank-tab-single")
    if errors:
        return errors
    if input_row(screen) != ".pi/":
        errors.append(f"at-blank-tab-single: input row is {input_row(screen)!r}, want '.pi/'")
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"at-blank-tab-single: menu residue after Tab: {residue!r}")
    return errors


def validate_prompt_filter(milestone: dict) -> list[str]:
    """B1-R3-07/R4-08: prompt candidates carry their real descriptions and
    the [p] source tag."""
    screen = milestone.get("screen")
    name = milestone.get("milestone", "slash-prompt-filter")
    joined, errors = _joined(screen, name)
    if errors:
        return errors
    if name == "slash-prompt-filter":
        want_input, want_names = "/code-r", ["code-review"]
    else:
        want_input, want_names = "/commit", ["commit-msg"]
    if input_row(screen) != want_input:
        errors.append(f"{name}: input row is {input_row(screen)!r}, want {want_input!r}")
    names = candidate_names(screen)
    if names != want_names:
        errors.append(f"{name}: candidates {names!r}, want {want_names!r}")
    rows = candidate_rows(screen)
    if rows is None:
        errors.append(f"{name}: candidate rows not found")
    else:
        for row in rows:
            if "[p]" not in row:
                errors.append(f"{name}: missing [p] source tag in {row!r}")
            if "Quit Adou" in row:
                errors.append(f"{name}: fallback description on {row!r}")
    return errors


def validate_login_filter(milestone: dict) -> list[str]:
    """B1-R2-04/R4-08: /login lists only API-key providers with real names;
    the OAuth-only openai-codex never appears."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-login-filter")
    if errors:
        return errors
    if input_row(screen) != "/login deepseek":
        errors.append(f"slash-login-filter: input row is {input_row(screen)!r}, want '/login deepseek'")
    names = candidate_names(screen)
    if names is None or names != ["deepseek"]:
        errors.append(f"slash-login-filter: candidates {names!r}, want ['deepseek']")
    joined_rows = "\n".join(screen)
    if "openai-codex" in joined_rows:
        errors.append("slash-login-filter: OAuth-only openai-codex must never appear as an API-key candidate")
    if "DeepSeek · API key" not in joined_rows:
        errors.append("slash-login-filter: deepseek row missing its real API-key metadata")
    return errors


EXPECTED_TAB_REOPEN = ("model", "scoped-models", "import")


def validate_tab_reopen(milestone: dict) -> list[str]:
    """B1-R2-01: Tab with no active menu only re-requests the candidates;
    the editor text stays '/mo', the model/scoped-models/import menu reopens
    and nothing is submitted (Pi 0.82.1 oracle semantics)."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-tab-reopen")
    if errors:
        return errors
    if input_row(screen) != "/mo":
        errors.append(f"slash-tab-reopen: input row is {input_row(screen)!r}, want '/mo' (Tab must not apply)")
    names = candidate_names(screen)
    if names != list(EXPECTED_TAB_REOPEN):
        errors.append(f"slash-tab-reopen: candidates {names!r}, want {list(EXPECTED_TAB_REOPEN)!r}")
    if selected_name(screen) != "model":
        errors.append(f"slash-tab-reopen: selected {selected_name(screen)!r}, want 'model'")
    chat = chat_rows(screen)
    if chat is not None and any(row.strip() != "" for row in chat):
        errors.append(f"slash-tab-reopen: Tab must not submit, chat area changed: {chat!r}")
    return errors


def validate_tab_apply(milestone: dict) -> list[str]:
    """B1-R1-01/03: Tab applies the completion without submitting; the
    applied line is '/model ' and the menu closes."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-tab-apply")
    if errors:
        return errors
    if input_row(screen) != "/model":
        errors.append(f"slash-tab-apply: input row is {input_row(screen)!r}, want '/model ' (visible rows strip the trailing space; the raw-slice assertion covers it)")
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"slash-tab-apply: menu residue after Tab: {residue!r}")
    chat = chat_rows(screen)
    if chat is not None and any(row.strip() != "" for row in chat):
        errors.append(f"slash-tab-apply: Tab must not submit, chat area changed: {chat!r}")
    return errors


def validate_arg_enter(milestone: dict) -> list[str]:
    """B1-R1-02/03: Enter on the argument menu applies the selected model
    value and does not submit the line."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-arg-enter")
    if errors:
        return errors
    want = "/model " + MODEL
    if input_row(screen) != want:
        errors.append(f"slash-arg-enter: input row is {input_row(screen)!r}, want {want!r}")
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"slash-arg-enter: menu residue after Enter: {residue!r}")
    chat = chat_rows(screen)
    if chat is not None and any(row.strip() != "" for row in chat):
        errors.append(f"slash-arg-enter: Enter must not submit, chat area changed: {chat!r}")
    return errors


def validate_paste(milestone: dict) -> list[str]:
    """B1-R1-05: a pasted '/' inserts the character but never opens the
    slash menu."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-paste")
    if errors:
        return errors
    if input_row(screen) != "/":
        errors.append(f"slash-paste: input row is {input_row(screen)!r}, want '/'")
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"slash-paste: pasted '/' must not open the menu: {residue!r}")
    return errors


def validate_multiline(milestone: dict) -> list[str]:
    """B1-R1-04: the slash menu only exists on the first editor line; a '/'
    on any other line is plain text."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-multiline")
    if errors:
        return errors
    lines = editor_lines(screen)
    if lines != [" x", " /"]:
        errors.append(f"slash-multiline: editor lines {lines!r}, want [' x', ' /']")
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"slash-multiline: second-line '/' must not open the menu: {residue!r}")
    return errors


def validate_model_enter(milestone: dict) -> list[str]:
    """IP-001 / B1-R1-03: '/model' Enter enters the model selector, never
    the scoped-models overlay."""
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-model-enter")
    if errors:
        return errors
    if "Select model:" not in joined:
        errors.append("slash-model-enter: model selector did not open ('Select model:' missing)")
    if "Model Configuration" in joined:
        errors.append("slash-model-enter: entered scoped-models instead of the model selector")
    if "Model Name:" not in joined:
        errors.append("slash-model-enter: selector detail row missing")
    return errors


def validate_model_esc(milestone: dict) -> list[str]:
    screen = milestone.get("screen")
    joined, errors = _joined(screen, "slash-model-esc")
    if errors:
        return errors
    if "Select model:" in joined or "Model Configuration" in joined:
        errors.append("slash-model-esc: selector still open after Esc")
    residue = esc_residue_rows(screen)
    if residue:
        errors.append(f"slash-model-esc: selector residue after Esc: {residue!r}")
    return errors


VALIDATORS = {
    "startup": validate_startup,
    "slash-open": validate_slash_open,
    "slash-up-wrap": validate_wrap,
    "slash-down": validate_down,
    "slash-page": validate_page,
    "slash-skill-filter": validate_skill_filter,
    "slash-esc-closed": validate_esc,
    "slash-ctrl-c": validate_ctrl_c,
    "slash-tab-reopen": validate_tab_reopen,
    "slash-tab-apply": validate_tab_apply,
    "slash-arg-enter": validate_arg_enter,
    "slash-paste": validate_paste,
    "slash-multiline": validate_multiline,
    "slash-model-enter": validate_model_enter,
    "slash-model-esc": validate_model_esc,
    "at-email-literal": validate_at_email,
    "at-clear-1": validate_cleared,
    "at-one-candidate": validate_at_one,
    "at-type-requery": validate_at_requery,
    "at-backspace-requery": validate_at_backspace_requery,
    "at-wrap-up": validate_at_wrap,
    "at-wrap-down": validate_at_wrap,
    "at-active-tab": validate_at_active_tab,
    "at-clear-2": validate_cleared,
    "at-dir-apply": validate_at_dir_apply,
    "at-clear-3": validate_cleared,
    "at-no-candidate-tab": validate_at_no_candidate,
    "at-clear-4": validate_cleared,
    "at-blank-tab-single": validate_at_blank_tab,
    "at-clear-5": validate_cleared,
    "slash-prompt-filter": validate_prompt_filter,
    "at-esc-1": validate_esc_only,
    "at-clear-6": validate_cleared,
    "slash-prompt-filter-2": validate_prompt_filter,
    "at-esc-2": validate_esc_only,
    "at-clear-7": validate_cleared,
    "slash-login-filter": validate_login_filter,
    "at-esc-3": validate_esc_only,
}

# Raw-slice predicates: per-milestone boolean checks over the checkpointed
# raw bytes (visible rows strip trailing spaces, so the @file completion
# space lives in the emitted stream only).
RAW_PREDICATES = {
    "at-active-tab": (
        lambda raw: b"commit-msg.md " in raw or b"code-review.md " in raw,
        "attachment file completion carries the trailing space",
    ),
}


EXPECTED_MILESTONES = ["startup"] + list(MILESTONE_KEYS.keys())


def validate_record(record: dict) -> list[str]:
    errors: list[str] = []
    if record.get("exit_code") != 0:
        errors.append(f"exit_code must be 0, got {record.get('exit_code')!r}")
    milestones = record.get("milestones")
    if not isinstance(milestones, list) or len(milestones) != len(EXPECTED_MILESTONES):
        count = len(milestones) if isinstance(milestones, list) else "none"
        return [f"expected {len(EXPECTED_MILESTONES)} milestones, got {count}"]
    names = [m.get("milestone") for m in milestones]
    if names != EXPECTED_MILESTONES:
        errors.append(f"milestone order {names!r}, want {EXPECTED_MILESTONES!r}")
        return errors
    by_name = {m.get("milestone"): m for m in milestones}
    for name, validator in VALIDATORS.items():
        errors.extend(validator(by_name.get(name, {})))
    return errors


def adou_argv() -> list[str]:
    return [
        os.environ["ADOU_BIN"],
        "--offline",
        "--approve",
        "--no-context-files",
        "--no-session",
        "--provider",
        "deepseek",
        "--model",
        MODEL,
        "--thinking",
        "off",
        "--max-tokens",
        "128",
    ]


def fixture_max_visible(name: str) -> int:
    """Parse autocompleteMaxVisible from the fixture's settings.json."""
    settings_path = os.path.join(FIXTURES[name], "home", ".pi", "agent", "settings.json")
    try:
        with open(settings_path) as fh:
            data = json.load(fh)
        return int(data.get("autocompleteMaxVisible", 5))
    except (OSError, ValueError, TypeError):
        return 5


def adou_head() -> str:
    """Current working-tree HEAD recorded on every evidence record so the
    parity comparator can cross-check it (B1-R6 rework C)."""
    import subprocess  # noqa: E402

    result = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True, check=False)
    return result.stdout.strip() or "unknown"


def adou_binary_sha256() -> str:
    """sha256 of the actual ADOU_BIN bytes (B1-R6 rework C/F2)."""
    binary = os.environ["ADOU_BIN"]
    with open(binary, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def adou_source_fingerprint() -> str:
    """Deterministic hash over the Makefile build inputs (B1-R6 rework C):
    main.n, package.toml, src/**/*.n (incl. UNTRACKED files — never just
    git diff), native/*.c and scripts/nature-build-safe.sh, sorted by
    repo-relative path with path+content hashed.  Identical algorithm to
    max-visible-parity.adou_source_fingerprint()."""
    inputs: list[str] = []
    for rel in ("main.n", "package.toml", "scripts/nature-build-safe.sh"):
        if os.path.exists(os.path.join(ROOT, rel)):
            inputs.append(rel)
    for prefix, suffix in (("src", ".n"), ("native", ".c")):
        base = os.path.join(ROOT, prefix)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirs, files in os.walk(base):
            for name in files:
                if name.endswith(suffix):
                    inputs.append(os.path.relpath(os.path.join(dirpath, name), ROOT))
    inputs.sort()
    digest = hashlib.sha256()
    for rel in inputs:
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        with open(os.path.join(ROOT, rel), "rb") as fh:
            digest.update(fh.read())
    return digest.hexdigest()


def capture(case: PtyCase, name: str, quiet: float = 0.6, timeout: float = 10.0) -> tuple[dict, bytes]:
    case.checkpoint()
    case.drain(quiet=quiet, timeout=timeout)
    return snapshot(case, name)


def snapshot(case: PtyCase, name: str) -> tuple[dict, bytes]:
    """Milestone record without touching the checkpoint/drain state: the raw
    slice is whatever accumulated since the caller's checkpoint, and the
    screen is the current VT state."""
    raw_slice = case.raw_slice()
    screen = [normalize_text(row, ROOT) for row in case.screen_rows()]
    normalized_raw = normalize_raw_bytes(raw_slice, ROOT)
    milestone = {
        "milestone": name,
        "screen": screen,
        "screen_sha256": hashlib.sha256("\n".join(screen).encode("utf-8")).hexdigest(),
        "cursor": list(case.cursor()),
        "normalized_raw_sha256": hashlib.sha256(normalized_raw).hexdigest(),
        "normalized_raw_bytes": len(normalized_raw),
    }
    return milestone, raw_slice


def run_one(case: PtyCase, barrier_quiet: float = 0.6, barrier_hold: float = 0.5) -> tuple[list[dict], list[bytes], int | None, list[str]]:
    milestones: list[dict] = []
    raw_slices: list[bytes] = []
    raw_checks: list[dict] = []
    failures: list[str] = []
    code = None
    try:
        case.wait_ready(timeout=25.0)
        milestone, raw_slice = capture(case, "startup")
        milestones.append(milestone)
        raw_slices.append(raw_slice)
        for name, keys in MILESTONE_KEYS.items():
            # The milestone's raw slice starts HERE (before the keys), so the
            # barrier's drained output still belongs to this milestone.
            case.checkpoint()
            # Settle between milestone groups: Adou's input buffer holds a
            # pending ESC for its 50ms escape window, and a control byte
            # written immediately after can merge into one CSI-u frame and
            # be silently dropped (observed as a one-off lost Ctrl+C/Esc).
            time.sleep(0.12)
            # B1-R5-01 post-input processing barrier: the mark is taken
            # BEFORE the keys, and drain_after_input only returns after the
            # child emitted output beyond that mark followed by quiet (or, for
            # genuinely no-op batches, after a short hold with the child
            # confirmed alive).  A plain drain can return before a lagging
            # child processes the batch, letting Ctrl+C keys from different
            # milestones collapse into one 500ms double-press window.  A dead
            # child never passes the hold and surfaces as a timeout/EIO.
            case.mark_input()
            for key in keys:
                try:
                    case.send_bytes(key.encode("utf-8") if isinstance(key, str) else key)
                except OSError as exc:
                    # The child exited mid-run (rare, observed with the max20
                    # layout): record it honestly instead of crashing the
                    # runner; the run verdict becomes FAIL.
                    failures.append(f"run: child died while sending milestone {name} keys ({exc})")
                    code = case.wait_exit(timeout=5.0)
                    if code is None:
                        code = -1
                    raise _ChildDied(name)
            try:
                case.drain_after_input(quiet=barrier_quiet, timeout=10.0, no_output_hold=barrier_hold)
            except PtyTimeout as exc:
                failures.append(f"run: milestone {name} produced no post-input output ({exc})")
                code = case.wait_exit(timeout=5.0)
                if code is None:
                    code = -1
                raise _ChildDied(name)
            milestone, raw_slice = snapshot(case, name)
            milestones.append(milestone)
            raw_slices.append(raw_slice)
            for needle, description in RAW_NEEDLES.get(name, []):
                found = needle in raw_slice
                raw_checks.append({
                    "milestone": name,
                    "needle": needle.hex(),
                    "description": description,
                    "found": found,
                })
                if not found:
                    failures.append(f"{name}: raw slice lacks {description} (needle {needle.hex()})")
            if name in RAW_PREDICATES:
                predicate, description = RAW_PREDICATES[name]
                found = predicate(raw_slice)
                raw_checks.append({
                    "milestone": name,
                    "predicate": description,
                    "found": found,
                })
                if not found:
                    failures.append(f"{name}: raw slice fails {description}")
        # Quit: ctrl+c clears the editor, then type /quit key-by-key so the
        # command menu opens, then Enter applies and submits it.
        for key in QUIT_KEYS:
            case.send_bytes(key.encode("utf-8") if isinstance(key, str) else key)
        code = case.wait_exit(timeout=15.0)
    except _ChildDied:
        # The child already exited mid-run; the failure was recorded above.
        if code is None:
            code = -1
    except PtyTimeout as exc:
        failures.append(f"run: {exc}")
        code = None
    finally:
        case.close()
    return milestones, raw_slices, code, failures, raw_checks


def main() -> int:
    global FIXTURE, HOME, AGENT, CWD, MAX_VISIBLE
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--fixture", default="batch1", choices=list(FIXTURES.keys()),
                        help="batch1 (max 5) or the autocompleteMaxVisible 3/20 variants")
    parser.add_argument("--out", default=None)
    parser.add_argument("--self-test", action="store_true", help="run the pure validator self-tests without a PTY")
    parser.add_argument("--raw-dir", default=None, help="dump exact raw ANSI slices to a local dir (diagnostics only)")
    parser.add_argument("--barrier-quiet", type=float, default=0.6,
                        help="post-input barrier quiet window in seconds (B1-R5-01)")
    parser.add_argument("--barrier-hold", type=float, default=0.5,
                        help="post-input barrier no-output hold in seconds for no-op batches (B1-R5-01)")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    if validate_runs(args.runs):
        parser.error(f"--runs must be >= {MIN_RUNS} (three-round gate), got {args.runs}")

    FIXTURE = FIXTURES[args.fixture]
    HOME = os.path.join(FIXTURE, "home")
    AGENT = os.path.join(HOME, ".pi", "agent")
    CWD = os.path.join(FIXTURE, "cwd")
    MAX_VISIBLE = fixture_max_visible(args.fixture)

    out_dir = args.out or os.path.join(ROOT, "docs", "pi-batch1-evidence")
    os.makedirs(out_dir, exist_ok=True)

    env = fixed_oracle_env(HOME, agent_dir=AGENT)
    fixture_norm = {key: normalize_text(value, ROOT) for key, value in {"home": HOME, "agent": AGENT, "cwd": CWD}.items()}
    username = os.environ.get("USER") or os.environ.get("LOGNAME") or ""

    records: list[dict] = []
    screens_by_milestone: dict[str, list[list[str]]] = {}
    consistency_failures: list[str] = []

    for run in range(1, args.runs + 1):
        case = PtyCase(adou_argv(), env, CWD, rows=ROWS, cols=COLS, ready_marker=ADOU_READY)
        case.start()
        milestones, raw_slices, code, run_failures, raw_checks = run_one(case, barrier_quiet=args.barrier_quiet, barrier_hold=args.barrier_hold)
        if run_failures:
            consistency_failures.extend(run_failures)

        record = {
            "case": "slash-menu",
            "side": "adou",
            "fixture": args.fixture,
            "adou_head": adou_head(),
            "binary_sha256": adou_binary_sha256(),
            "source_fingerprint": adou_source_fingerprint(),
            "run": run,
            "terminal": {"rows": ROWS, "cols": COLS},
            "precondition": {
                "offline": True,
                "api_keys": "fixture (deepseek sentinel)",
                "home": fixture_norm["home"],
                "agent_dir": fixture_norm["agent"],
                "cwd": fixture_norm["cwd"],
                "skills": ["alpha-toolkit", "beta-ops"],
                "prompts": ["code-review", "commit-msg"],
                "model": MODEL,
                "settings": {"theme": "dark", "autocompleteMaxVisible": MAX_VISIBLE},
                "llama_extension": "EXCLUDED (Pi inline extension, out of Adou product scope)",
            },
            "keys": {
                name: [k.encode("utf-8").hex() for k in keys]
                for name, keys in MILESTONE_KEYS.items()
            },
            "quit_keys": [k.encode("utf-8").hex() for k in QUIT_KEYS],
            "milestones": milestones,
            "raw_assertions": raw_checks,
            "exit_code": code,
        }
        errors = validate_record(record)
        leaks = evidence_leaks(record, [ROOT, username])
        if leaks:
            errors.append(f"evidence leaks local markers: {leaks!r}")
        record["assertions"] = {"verdict": "PASS" if not errors else "FAIL", "failures": errors}
        records.append(record)

        evidence_path = os.path.join(out_dir, f"evidence-adou-{args.fixture}-{run}.json")
        with open(evidence_path, "w") as fh:
            json.dump(record, fh, indent=2, ensure_ascii=False)
        print(f"run {run}: exit={code} assertions={record['assertions']['verdict']}")

        if args.raw_dir:
            os.makedirs(args.raw_dir, exist_ok=True)
            for milestone, raw_slice in zip(milestones, raw_slices):
                dump_path = os.path.join(args.raw_dir, f"raw-adou-{run}-{milestone['milestone']}.ansi")
                with open(dump_path, "wb") as fh:
                    fh.write(raw_slice)
        for milestone in milestones:
            screens_by_milestone.setdefault(milestone["milestone"], []).append(milestone["screen"])

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
        {"run": r.get("run"), "exit_code": r.get("exit_code"), "assertions": r.get("assertions")}
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
        "case": "slash-menu",
        "side": "adou",
        "fixture": args.fixture,
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
            "consecutive checkpoints AFTER bytes-level <REPO> normalization; "
            "exact raw ANSI is never committed (--raw-dir dumps it locally "
            "for diagnostics only)."
        ),
    }
    summary_path = os.path.join(out_dir, f"summary-adou-{args.fixture}.json")
    with open(summary_path, "w") as fh:
        json.dump(summary, fh, indent=2, ensure_ascii=False)
    print("summary:", summary_path)

    if not all_ok:
        print("slash-menu FAILED:", file=sys.stderr)
        for failure in consistency_failures:
            print(" -", failure, file=sys.stderr)
        for r in records:
            for failure in r.get("assertions", {}).get("failures", []):
                print(f" - run {r.get('run')}: {failure}", file=sys.stderr)
        return 1
    print(f"slash-menu OK: {args.runs} runs, semantic assertions PASS, "
          f"screens identical, all exit codes 0")
    return 0


# -- pure validator self-tests (no PTY) -------------------------------------


def _blank_screen() -> list[str]:
    return [""] * COLS


def _make_screen(input_text: str, editor_before: list[str] | None = None,
                 candidates: list[tuple[str, str]] | None = None,
                 pager_value: tuple[int, int] | None = None,
                 selected: str | None = None, status: bool = True) -> list[str]:
    """Synthetic Adou screen: editor borders at row 1 and bottom, candidate
    rows and pager right below the bottom border, then the cwd/status block.
    Mirrors the real layout (bottom+1 = cwd row, bottom+2 = status row when
    there are no candidates)."""
    screen = _blank_screen()
    screen[1] = BORDER
    lines = editor_before if editor_before is not None else [input_text]
    for i, line in enumerate(lines):
        screen[2 + i] = line
    bottom = 2 + len(lines)
    screen[bottom] = BORDER
    if candidates is not None:
        for i, (name, description) in enumerate(candidates):
            prefix = "→ " if name == selected else "  "
            screen[bottom + 1 + i] = f"{prefix}{name:<18s} {description}"
    if pager_value is not None:
        pager_row = bottom + 1 + len(candidates or [])
        screen[pager_row] = f"  ({pager_value[0]}/{pager_value[1]})"
    if status:
        status_base = bottom + 1 + len(candidates or []) + (1 if pager_value else 0)
        screen[status_base] = "<REPO>/tests/e2e/lib/pi-oracle/fixtures/batch1/cwd (main)"
        screen[status_base + 1] = "0.0%/1M (auto)                                deepseek-v4-flash • thinking off"
    return screen


def _milestone(name: str, screen: list[str]) -> dict:
    return {"milestone": name, "screen": screen}


def _selector_screen() -> list[str]:
    """Synthetic model-selector screen (open state)."""
    screen = _blank_screen()
    screen[1] = BORDER
    screen[2] = ""
    screen[3] = BORDER
    screen[4] = " Select model:"
    screen[5] = " Scope: All  (Tab to switch)"
    screen[8] = " → deepseek-v4-flash [deepseek] ✓"
    screen[10] = " Model Name: DeepSeek V4 Flash"
    return screen


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
        ("code-review", "[p] Deterministic fixture prompt code-review for parity"),
    ]
    skill_candidates = [
        ("skill:alpha-toolkit", "[p] Deterministic fixture skill alpha-toolkit for parit"),
        ("skill:beta-ops", "[p] Deterministic fixture skill beta-ops for parity run"),
    ]
    prompt_candidates = [
        ("code-review", "[p] Deterministic fixture prompt code-review for parity"),
        ("commit-msg", "[p] Deterministic fixture prompt commit-msg for parity run"),
    ]
    at_two_candidates = [
        ("code-review.md", ".pi/prompts/code-review.md"),
        ("commit-msg.md", ".pi/prompts/commit-msg.md"),
    ]
    at_one_candidates = [("commit-msg.md", ".pi/prompts/commit-msg.md")]
    login_candidates = [("deepseek", "DeepSeek · API key")]
    empty_editor = _make_screen("", editor_before=["", ""])
    return {
        "exit_code": 0,
        "milestones": [
            _milestone("startup", _make_screen("", editor_before=["", ""])),
            _milestone("slash-open", _make_screen("/", candidates=open_candidates, pager_value=(1, 26), selected="settings")),
            _milestone("slash-up-wrap", _make_screen("/", candidates=wrap_candidates, pager_value=(13, 26), selected="clone")),
            _milestone("slash-down", _make_screen("/", candidates=down_candidates, pager_value=(21, 26), selected="reload")),
            _milestone("slash-page", _make_screen("/", candidates=down_candidates, pager_value=(21, 26), selected="reload")),
            _milestone("slash-skill-filter", _make_screen("/skill:", candidates=skill_candidates, selected="skill:alpha-toolkit")),
            _milestone("slash-esc-closed", _make_screen("/skill:")),
            _milestone("slash-ctrl-c", empty_editor),
            _milestone("slash-tab-reopen", _make_screen(
                "/mo",
                candidates=[
                    ("model", "<provider/model> — Select model (opens selector UI)"),
                    ("scoped-models", "Enable/disable models for Ctrl+P cycling"),
                    ("import", "Import and resume a session from a JSONL file"),
                ],
                selected="model",
            )),
            _milestone("slash-tab-apply", _make_screen("/model ")),
            _milestone("slash-arg-enter", _make_screen("/model deepseek/deepseek-v4-flash")),
            _milestone("slash-paste", _make_screen("/")),
            _milestone("slash-multiline", _make_screen("", editor_before=[" x", " /"])),
            _milestone("slash-model-enter", _selector_screen()),
            _milestone("slash-model-esc", empty_editor),
            _milestone("at-email-literal", _make_screen("me@domain")),
            _milestone("at-clear-1", empty_editor),
            _milestone("at-one-candidate", _make_screen("@co", candidates=at_two_candidates, selected="code-review.md")),
            _milestone("at-type-requery", _make_screen("@com", candidates=at_one_candidates, selected="commit-msg.md")),
            _milestone("at-backspace-requery", _make_screen("@co", candidates=at_two_candidates, selected="code-review.md")),
            _milestone("at-wrap-up", _make_screen("@co", candidates=at_two_candidates, selected="commit-msg.md")),
            _milestone("at-wrap-down", _make_screen("@co", candidates=at_two_candidates, selected="code-review.md")),
            _milestone("at-active-tab", _make_screen("@.pi/prompts/code-review.md")),
            _milestone("at-clear-2", empty_editor),
            _milestone("at-dir-apply", _make_screen("@.pi/")),
            _milestone("at-clear-3", empty_editor),
            _milestone("at-no-candidate-tab", _make_screen("zzzz-no-such-entry")),
            _milestone("at-clear-4", empty_editor),
            _milestone("at-blank-tab-single", _make_screen(".pi/")),
            _milestone("at-clear-5", empty_editor),
            _milestone("slash-prompt-filter", _make_screen("/code-r", candidates=[("code-review", "[p] Deterministic fixture prompt code-review for parity")], selected="code-review")),
            _milestone("at-esc-1", _make_screen("/code-r")),
            _milestone("at-clear-6", empty_editor),
            _milestone("slash-prompt-filter-2", _make_screen("/commit", candidates=[("commit-msg", "[p] Deterministic fixture prompt commit-msg for parity run")], selected="commit-msg")),
            _milestone("at-esc-2", _make_screen("/commit")),
            _milestone("at-clear-7", empty_editor),
            _milestone("slash-login-filter", _make_screen("/login deepseek", candidates=login_candidates, selected="deepseek")),
            _milestone("at-esc-3", _make_screen("/login deepseek")),
        ],
    }


def self_test() -> int:
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
    check("valid record verdict", validate_record(_valid_record()), [])

    # negative: non-zero / None exit
    record = _valid_record()
    record["exit_code"] = 5
    expect_error("non-zero exit", record, "exit_code must be 0")
    record = _valid_record()
    record["exit_code"] = None
    expect_error("None exit", record, "exit_code must be 0")

    # negative: missing milestone
    record = _valid_record()
    record["milestones"] = record["milestones"][:37]
    expect_error("missing milestone", record, "expected 38 milestones")

    # negative (B1-R5-01): an early child exit leaves partial milestones;
    # the record is rejected (milestone-count short-circuit), and the
    # runner's all_ok additionally requires exit_code == 0 + verdict PASS +
    # no consistency failures, so an early exit can never be a false green.
    record = _valid_record()
    record["milestones"] = record["milestones"][:9]
    record["exit_code"] = -1
    errors = validate_record(record)
    if not errors:
        failures.append("early-exit record accepted, expected milestone error")
    elif "expected 38 milestones" not in "\n".join(errors):
        failures.append(f"early-exit: milestone error missing, got: {errors}")
    all_ok_early_exit = (
        len([record]) >= MIN_RUNS
        and all(r.get("exit_code") == 0 and r.get("assertions", {}).get("verdict") == "PASS" for r in [record])
        and not []
    )
    if all_ok_early_exit:
        failures.append("early-exit record would pass the runner all_ok gate")

    # negative: wrong candidate order in slash-open
    record = _valid_record()
    open_screen = record["milestones"][1]["screen"]
    open_screen[4] = "  model                <provider/model> — Select model (opens selector UI)"
    open_screen[5] = "→ settings            Open settings menu"
    expect_error("wrong candidate order", record, "candidates")

    # negative: wrong pager after slash-open
    record = _valid_record()
    record["milestones"][1]["screen"][9] = "  (2/26)"
    expect_error("wrong pager", record, "pager")

    # negative: stale pager after PageDown
    record = _valid_record()
    record["milestones"][4]["screen"][9] = "  (4/26)"
    expect_error("page selection changed", record, "slash-page")

    # negative: Esc candidate residue WITHOUT a pager (false-green repro)
    record = _valid_record()
    record["milestones"][6]["screen"][4] = "  stale                Stale candidate"
    expect_error("esc candidate-only residue", record, "residue")

    # negative: Esc pager-only residue
    record = _valid_record()
    record["milestones"][6]["screen"][4] = "  (1/26)"
    expect_error("esc pager-only residue", record, "residue")

    # negative: Tab reopen must not apply the completion (B1-R2-01)
    record = _valid_record()
    record["milestones"][8]["screen"][2] = "/model "
    expect_error("tab-reopen applied", record, "must not apply")

    # negative: Tab reopen must re-request the candidates (no menu = fail)
    record = _valid_record()
    record["milestones"][8]["screen"][4] = ""
    record["milestones"][8]["screen"][5] = ""
    record["milestones"][8]["screen"][6] = ""
    expect_error("tab-reopen no menu", record, "candidates")

    # negative: Tab reopen must not submit
    record = _valid_record()
    record["milestones"][8]["screen"][0] = "submitted something"
    expect_error("tab-reopen submitted", record, "must not submit")

    # negative: Tab must not leave a menu open
    record = _valid_record()
    record["milestones"][9]["screen"][4] = "  (1/26)"
    expect_error("tab menu residue", record, "residue")

    # negative: arg-enter wrong value (command head must stay)
    record = _valid_record()
    record["milestones"][10]["screen"][2] = "/model deepseek/deepseek-v4-pro"
    expect_error("arg-enter wrong value", record, "want")

    # negative: multiline second-line menu residue
    record = _valid_record()
    record["milestones"][12]["screen"][5] = "→ settings            Open settings menu"
    expect_error("multiline residue", record, "must not open the menu")

    # negative: /model entered scoped-models (replaces the bottom border so
    # the editor helpers break; the joined-text check still must fire)
    record = _valid_record()
    record["milestones"][13]["screen"][3] = " Model Configuration"
    expect_error("model selector wrong overlay", record, "scoped-models")

    # negative: model selector still open after Esc
    record = _valid_record()
    record["milestones"][14]["screen"][3] = " Select model:"
    expect_error("model esc residue", record, "still open")

    # negative: email literal must not open a menu (B1-R4-04)
    record = _valid_record()
    record["milestones"][15]["screen"][4] = "  stale                Stale candidate"
    expect_error("email literal menu", record, "must not open a menu")

    # negative: natural one-candidate @ input must OPEN the list, not apply
    record = _valid_record()
    record["milestones"][17]["screen"][4] = ""
    record["milestones"][17]["screen"][5] = ""
    record["milestones"][17]["screen"][6] = ""
    expect_error("at-one no list", record, "list must open")

    # negative: typing requery must narrow to a single candidate
    record = _valid_record()
    record["milestones"][18]["screen"][4] = "  code-review.md       .pi/prompts/code-review.md"
    record["milestones"][18]["screen"][5] = "  commit-msg.md        .pi/prompts/commit-msg.md"
    expect_error("requery no shrink", record, "want ['commit-msg.md']")

    # negative: wrap-up must land on the LAST candidate
    record = _valid_record()
    record["milestones"][20]["screen"][4] = "→ code-review.md      .pi/prompts/code-review.md"
    expect_error("wrap-up wrong selection", record, "selected")

    # negative: active Tab must insert a relative value (no absolute cwd)
    record = _valid_record()
    record["milestones"][22]["screen"][2] = "@.pi/prompts//Users/someone/x"
    expect_error("active-tab absolute leak", record, "absolute cwd leaked")

    # negative: no-candidate Tab must leave the text untouched
    record = _valid_record()
    record["milestones"][26]["screen"][2] = "zzzz-no-such-entryX"
    expect_error("no-candidate text changed", record, "want 'zzzz-no-such-entry'")

    # negative: blank Tab single candidate must apply '.pi/'
    record = _valid_record()
    record["milestones"][28]["screen"][2] = ""
    expect_error("blank-tab no apply", record, "want '.pi/'")

    # negative: login must never show the OAuth-only provider
    record = _valid_record()
    record["milestones"][36]["screen"][5] = "  openai-codex         OpenAI Codex · API key"
    expect_error("login oauth leak", record, "openai-codex")

    # runs gate
    check("runs gate 3 ok", validate_runs(3), [])
    for runs in (0, 1, 2):
        errors = validate_runs(runs)
        if not errors:
            failures.append(f"runs gate: {runs} accepted")
        elif "three-round gate" not in "\n".join(errors):
            failures.append(f"runs gate: {runs} error lacks gate text: {errors}")

    if failures:
        print("slash-menu self-test FAILED:")
        for failure in failures:
            print(" -", failure)
        return 1
    print("slash-menu self-test OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
