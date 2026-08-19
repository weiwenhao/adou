#!/usr/bin/env python3
"""Shared PTY driver for the Pi/Adou interactive parity protocol.

pi-interactive-parity-audit-plan.md, Batch 0 (rework). The same driver
launches the Pi 0.82.1 oracle (vendors/pi) and the Adou TUI, because both
render full-screen ANSI and emit a keyboard-ready marker at startup:

- Pi 0.82.1: `ESC[>7u` (DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 7), followed
  by `ESC[?u` and `ESC[c`.
- Adou:      `ESC[>1u` (src/tui/term.n KEYBOARD_PROTOCOL_ON).

DEFAULT_READY_MARKER reflects the Pi oracle; Adou runs pass the Adou marker
explicitly.

Contract:
- start(argv, env, cwd): exec with the EXACT env mapping passed in. The child
  environment is replaced (execvpe), so variables inherited from the parent
  are NOT leaked into the child; fixed_oracle_env() builds the minimal
  allowlist (credentials and proxies are excluded by construction).
- wait_ready(timeout): keyboard-ready marker seen; buffer reset at marker.
- checkpoint() / raw_slice(): explicit raw-ANSI boundaries. Evidence must
  never present the cumulative buffer as a single-step slice.
- drain(quiet, timeout), send_sequence/send_keys (key-by-key input),
  screen() normalized visible screen + cursor, wait_exit(timeout),
  close() (reaps; never SIGKILLs an already-reaped PID).
"""

from __future__ import annotations

import errno
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vt_screen import VTParser  # noqa: E402

DEFAULT_ROWS = 24
DEFAULT_COLS = 80
# Pi 0.82.1 keyboard-ready marker (Kitty protocol query). Adou emits
# `ESC[>1u` instead; Adou runs pass ready_marker=b"\x1b[>1u".
DEFAULT_READY_MARKER = b"\x1b[>7u"
DEFAULT_QUIET = 0.4  # seconds without output => drained

# Minimal fixed allowlist for the oracle child environment. Anything not
# listed here (credentials, proxies, tokens, npm config, ...) is dropped by
# construction. PATH and TMPDIR are carried from the parent; the rest are
# fixed so runs are reproducible on any host.
ENV_FIXED = {
    "TERM": "xterm-256color",
    "LANG": "en_US.UTF-8",
    "LC_ALL": "en_US.UTF-8",
    "LC_CTYPE": "en_US.UTF-8",
}
ENV_CARRIED = ("PATH", "TMPDIR")


class PtyTimeout(Exception):
    pass


class PtyCase:
    """One interactive run under the shared PTY protocol."""

    def __init__(
        self,
        argv: list[str],
        env: dict[str, str],
        cwd: str,
        rows: int = DEFAULT_ROWS,
        cols: int = DEFAULT_COLS,
        ready_marker: bytes = DEFAULT_READY_MARKER,
    ):
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.rows = rows
        self.cols = cols
        self.ready_marker = ready_marker
        self.raw = bytearray()
        self._raw_mark = 0
        self._input_mark = 0
        self.vt = VTParser(rows, cols)
        self.pid: Optional[int] = None
        self.fd: Optional[int] = None
        self.exit_code: Optional[int] = None
        self.reaped = False
        self.ready_seen = False
        self.started_at: Optional[float] = None

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> None:
        pid, fd = pty.fork()
        if pid == 0:  # child
            try:
                os.chdir(self.cwd)
                # execvpe replaces the whole environment: only self.env
                # survives, nothing inherited from the parent.
                os.execvpe(self.argv[0], self.argv, self.env)
            except BaseException:
                os._exit(127)
        self.pid = pid
        self.fd = fd
        self._last_data = time.time()
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.cols, 0, 0))
        self.started_at = time.time()

    def close(self) -> None:
        """Close the PTY and clean up the child.

        A child that already exited (reaped by wait_exit) has self.pid set
        to None, so close() never SIGKILLs a reaped PID and never hits a
        PID-reuse window. A still-running child is SIGKILLed and reaped.
        """
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None
        if self.pid is not None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                os.waitpid(self.pid, 0)
            except OSError:
                pass
            self.reaped = True
            self.pid = None

    # -- reading -----------------------------------------------------------

    def _read_available(self, timeout: float) -> bytes:
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return b""
        try:
            data = os.read(self.fd, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                return b""
            raise
        if data == b"":
            return b""
        self._last_data = time.time()
        self.raw.extend(data)
        self.vt.feed(data)
        return data

    def drain(self, quiet: float = DEFAULT_QUIET, timeout: float = 15.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            self._read_available(0.05)
            if time.time() - self._last_data > quiet:
                return
        raise PtyTimeout(f"stream did not quiet down within {timeout}s")

    def wait_ready(self, timeout: float = 20.0) -> None:
        deadline = time.time() + timeout
        marker_len = len(self.ready_marker)
        while time.time() < deadline:
            data = self._read_available(0.05)
            if data:
                self._last_data = time.time()
            idx = bytes(self.raw).find(self.ready_marker)
            if idx >= 0:
                # Drop everything before/at the marker; screen state after the
                # marker is what parity snapshots compare.
                del self.raw[: idx + marker_len]
                self._raw_mark = 0
                self.vt.reset()
                self.ready_seen = True
                return
        raise PtyTimeout(f"keyboard-ready marker {self.ready_marker!r} not seen within {timeout}s")

    # -- input -------------------------------------------------------------

    def send_bytes(self, data: bytes) -> None:
        if self.fd is None:
            raise RuntimeError("PTY not started")
        os.write(self.fd, data)

    def send_sequence(self, seq: bytes, per_key: float = 0.02) -> None:
        """Send a byte string key by key so the TUI sees discrete key events."""
        for byte in seq:
            self.send_bytes(bytes([byte]))
            if per_key > 0:
                time.sleep(per_key)

    def send_keys(self, keys: list[bytes], per_key: float = 0.02) -> None:
        for key in keys:
            self.send_sequence(key, per_key=per_key)

    # -- raw ANSI boundaries ------------------------------------------------

    def checkpoint(self) -> None:
        """Mark the start of a milestone raw-ANSI slice."""
        self._raw_mark = len(self.raw)

    def raw_slice(self) -> bytes:
        """Exact bytes written since the last checkpoint (or since the ready
        marker, if no checkpoint was taken)."""
        return bytes(self.raw[self._raw_mark :])

    def raw_ansi(self) -> bytes:
        """Full accumulated buffer since the ready marker. This is the
        cumulative stream, not a per-milestone slice; use checkpoint() and
        raw_slice() for step boundaries."""
        return bytes(self.raw)

    # -- post-input processing barrier ---------------------------------------

    def mark_input(self) -> None:
        """Record the raw length right before a batch of keys is written.
        The post-input barrier (drain_after_input) only counts output that
        arrives AFTER this mark, so a batch cannot be considered processed
        because of output left over from a previous batch."""
        self._input_mark = len(self.raw)

    def drain_after_input(self, quiet: float = DEFAULT_QUIET, timeout: float = 15.0,
                          no_output_hold: float = 0.3) -> None:
        """Post-input processing barrier: wait until the child has emitted at
        least one byte AFTER mark_input() and the stream is then quiet for
        `quiet` seconds.

        A plain drain(quiet) returns once `quiet` seconds have passed since
        the LAST received data — if the child was already quiet before the
        keys were written (e.g. it is busy rendering and its responses are
        delayed), the quiet period can elapse BEFORE the child processes the
        new input.  Two Ctrl+C keys from different milestones would then sit
        queued in the child and be processed in one burst, collapsing into a
        single 500ms double-press window.  This barrier prevents that by
        requiring observable processing output beyond the input mark.

        A batch can legitimately produce NO output (a no-op frame — e.g. a
        page key on a single-line editor yields renderer STRATEGY_NONE).  In
        that case the barrier falls back to a short `no_output_hold` wait,
        BUT only after confirming the child is still alive: a dead child
        must surface as a failure (PtyTimeout), never be swallowed by the
        hold.  Ctrl+C batches always change the screen in this protocol's
        milestone set, so the output path (and therefore the merge
        protection) applies to every Ctrl+C-carrying milestone."""
        deadline = time.time() + timeout
        saw_output_after_mark = False
        held_since = time.time()
        while time.time() < deadline:
            self._read_available(0.05)
            if len(self.raw) > self._input_mark:
                saw_output_after_mark = True
            if saw_output_after_mark:
                if time.time() - self._last_data > quiet:
                    return
            elif time.time() - held_since > no_output_hold:
                waited, status = os.waitpid(self.pid, os.WNOHANG)
                if waited:
                    raise PtyTimeout(f"child exited during no-output hold (status {status})")
                return
        raise PtyTimeout(f"no post-input output within {timeout}s (mark={self._input_mark}, raw={len(self.raw)})")

    # -- snapshot ----------------------------------------------------------

    def screen_rows(self) -> list[str]:
        return self.vt.screen.visible_rows()

    def screen_text(self) -> str:
        return self.vt.screen.visible_text()

    def cursor(self) -> tuple[int, int]:
        return (self.vt.screen.cursor_row, self.vt.screen.cursor_col)

    # -- exit --------------------------------------------------------------

    def wait_exit(self, timeout: float = 10.0) -> Optional[int]:
        """Wait for the child to exit and reap it.

        Once any exit status is obtained (including via ChildProcessError),
        self.pid is cleared so close() cannot SIGKILL a reaped PID (no
        PID-reuse window). Returns None on timeout; the caller must then
        close() to kill the still-running child.
        """
        if self.exit_code is not None:
            return self.exit_code
        if self.pid is None:
            return self.exit_code
        deadline = time.time() + timeout
        while time.time() < deadline:
            self._read_available(0.05)
            try:
                waited, status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                self.reaped = True
                self.pid = None
                return self.exit_code
            if waited:
                self.reaped = True
                self.exit_code = os.waitstatus_to_exitcode(status)
                self.pid = None
                return self.exit_code
            time.sleep(0.05)
        return None

    def quit_via_command(self, quit_cmd: bytes = b"/quit\r", timeout: float = 10.0) -> Optional[int]:
        self.send_bytes(quit_cmd)
        return self.wait_exit(timeout)


def fixed_oracle_env(base_home: str, *, agent_dir: str | None = None) -> dict[str, str]:
    """Exact environment mapping for oracle runs: minimal fixed allowlist.

    Credentials, proxies, tokens and anything else not in the allowlist are
    excluded by construction (never read, printed or persisted). HOME and
    ADOU_CODING_AGENT_DIR are pinned to the fixture paths; TERM and locale are
    fixed so screens are host-independent; PATH and TMPDIR are carried from
    the parent for Node/Pi subprocesses (tsx, git, bash).
    """
    env = dict(ENV_FIXED)
    for key in ENV_CARRIED:
        if key in os.environ:
            env[key] = os.environ[key]
    env["HOME"] = base_home
    if agent_dir is not None:
        env["ADOU_CODING_AGENT_DIR"] = agent_dir
    return env
