#!/usr/bin/env python3
"""Minimal VT100/ANSI screen interpreter producing a normalized visible screen.

Shared PTY protocol (pi-interactive-parity-audit-plan.md, Batch 0): both the Pi
oracle (0.82.1, vendors/pi) and the Adou TUI redraw with full-screen ANSI, so a
deterministic parity comparison needs a common VT interpreter instead of
ANSI-stripped linear text.

Supported: C0 controls, ESC (save/restore cursor, charsets, keypad), CSI
(cursor move, erase, insert/delete line/char, SGR, scroll margins, DEC modes),
OSC (title/hyperlinks, skipped), UTF-8 text with East Asian width. Sequence
types the TUIs do not emit are ignored rather than guessed.

The interpreter is pure Python stdlib. Run `python3 vt_screen.py` for a
self-test of the sequences the parity protocol relies on.
"""

from __future__ import annotations

import unicodedata

C0_IGNORE = frozenset(b"\x00\x01\x02\x03\x04\x05\x06\x07\x0e\x0f\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1c\x1d\x1e\x1f")


def cell_width(char: str) -> int:
    if unicodedata.combining(char):
        return 0
    return 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1


class Screen:
    """Fixed-size screen grid with cursor and scroll margins."""

    def __init__(self, rows: int = 24, cols: int = 80):
        self.rows = rows
        self.cols = cols
        self.grid: list[list[str]] = [[" "] * cols for _ in range(rows)]
        self.cursor_row = 0
        self.cursor_col = 0
        self.margin_top = 0
        self.margin_bottom = rows - 1
        self.saved_cursor = (0, 0)
        self.scroll_history = 0

    # -- text primitives ---------------------------------------------------

    def _scroll_up(self, top: int, bottom: int, count: int = 1) -> None:
        """Move rows [top..bottom] up by count; blank lines enter at bottom."""
        if count <= 0 or top > bottom:
            return
        span = bottom - top + 1
        count = min(count, span)
        self.grid[top : bottom + 1] = (
            self.grid[top + count : bottom + 1] + [[" "] * self.cols for _ in range(count)]
        )
        self.scroll_history += count

    def _scroll_down(self, top: int, bottom: int, count: int = 1) -> None:
        if count <= 0 or top > bottom:
            return
        span = bottom - top + 1
        count = min(count, span)
        self.grid[top : bottom + 1] = (
            [[" "] * self.cols for _ in range(count)] + self.grid[top : bottom + 1 - count]
        )

    def put_char(self, char: str) -> None:
        width = cell_width(char)
        if width == 0:
            if self.cursor_col > 0:
                self.grid[self.cursor_row][self.cursor_col - 1] += char
            return
        if self.cursor_col >= self.cols:
            self._linefeed()
            self.cursor_col = 0
        if width == 2 and self.cursor_col >= self.cols - 1:
            width = 1
        self.grid[self.cursor_row][self.cursor_col : self.cursor_col + width] = [char] + [" "] * (width - 1)
        self.cursor_col += width

    def newline(self) -> None:
        self.cursor_col = 0
        self._linefeed()

    def _linefeed(self) -> None:
        if self.cursor_row == self.margin_bottom:
            self._scroll_up(self.margin_top, self.margin_bottom)
        elif self.cursor_row < self.rows - 1:
            self.cursor_row += 1

    def carriage_return(self) -> None:
        self.cursor_col = 0

    def backspace(self) -> None:
        if self.cursor_col > 0:
            self.cursor_col -= 1

    def tab(self) -> None:
        self.cursor_col = min(self.cols - 1, ((self.cursor_col // 8) + 1) * 8)

    def reverse_index(self) -> None:
        if self.cursor_row == self.margin_top:
            self._scroll_down(self.margin_top, self.margin_bottom)
        elif self.cursor_row > 0:
            self.cursor_row -= 1

    # -- CSI operations ----------------------------------------------------

    def move_to(self, row: int, col: int) -> None:
        self.cursor_row = min(max(row - 1, 0), self.rows - 1)
        self.cursor_col = min(max(col - 1, 0), self.cols - 1)

    def move_up(self, n: int) -> None:
        self.cursor_row = max(self.cursor_row - n, 0)

    def move_down(self, n: int) -> None:
        self.cursor_row = min(self.cursor_row + n, self.rows - 1)

    def move_right(self, n: int) -> None:
        self.cursor_col = min(self.cursor_col + n, self.cols - 1)

    def move_left(self, n: int) -> None:
        self.cursor_col = max(self.cursor_col - n, 0)

    def set_column(self, n: int) -> None:
        self.cursor_col = min(max(n - 1, 0), self.cols - 1)

    def set_row(self, n: int) -> None:
        self.cursor_row = min(max(n - 1, 0), self.rows - 1)

    def erase_display(self, mode: int = 0) -> None:
        if mode in (2, 3):
            self.grid = [[" "] * self.cols for _ in range(self.rows)]
        elif mode == 1:
            for row in range(0, self.cursor_row):
                self.grid[row] = [" "] * self.cols
            self.grid[self.cursor_row][0 : self.cursor_col + 1] = [" "] * (self.cursor_col + 1)
        else:
            self.grid[self.cursor_row][self.cursor_col :] = [" "] * (self.cols - self.cursor_col)
            for row in range(self.cursor_row + 1, self.rows):
                self.grid[row] = [" "] * self.cols

    def erase_line(self, mode: int = 0) -> None:
        if mode == 2:
            self.grid[self.cursor_row] = [" "] * self.cols
        elif mode == 1:
            self.grid[self.cursor_row][0 : self.cursor_col + 1] = [" "] * (self.cursor_col + 1)
        else:
            self.grid[self.cursor_row][self.cursor_col :] = [" "] * (self.cols - self.cursor_col)

    def insert_lines(self, n: int) -> None:
        self._scroll_down(self.cursor_row, self.margin_bottom, n)

    def delete_lines(self, n: int) -> None:
        self._scroll_up(self.cursor_row, self.margin_bottom, n)

    def insert_chars(self, n: int) -> None:
        n = min(n, self.cols - self.cursor_col)
        row = self.grid[self.cursor_row]
        row[self.cursor_col :] = [" "] * n + row[self.cursor_col : self.cols - n]

    def delete_chars(self, n: int) -> None:
        n = min(n, self.cols - self.cursor_col)
        row = self.grid[self.cursor_row]
        row[self.cursor_col :] = row[self.cursor_col + n : self.cols] + [" "] * n

    def erase_chars(self, n: int) -> None:
        n = min(n, self.cols - self.cursor_col)
        self.grid[self.cursor_row][self.cursor_col : self.cursor_col + n] = [" "] * n

    def set_margins(self, top: int, bottom: int) -> None:
        self.margin_top = max(0, top - 1)
        self.margin_bottom = min(max(bottom - 1, self.margin_top), self.rows - 1)

    def scroll_up(self, n: int) -> None:
        self._scroll_up(self.margin_top, self.margin_bottom, n)

    def scroll_down(self, n: int) -> None:
        self._scroll_down(self.margin_top, self.margin_bottom, n)

    def save_cursor(self) -> None:
        self.saved_cursor = (self.cursor_row, self.cursor_col)

    def restore_cursor(self) -> None:
        self.cursor_row, self.cursor_col = self.saved_cursor

    def repeat_char(self, n: int, char: str) -> None:
        for _ in range(n):
            self.put_char(char)

    # -- normalized view ---------------------------------------------------

    def visible_rows(self) -> list[str]:
        """Normalized visible screen: each row right-trimmed of spaces."""
        return ["".join(row).rstrip(" ") for row in self.grid]

    def visible_text(self) -> str:
        return "\n".join(self.visible_rows())

    def __eq__(self, other: object) -> bool:
        return (
            isinstance(other, Screen)
            and self.visible_rows() == other.visible_rows()
            and self.cursor_row == other.cursor_row
            and self.cursor_col == other.cursor_col
        )


class VTParser:
    """Feed raw ANSI bytes (any chunking); maintain a normalized Screen."""

    def __init__(self, rows: int = 24, cols: int = 80):
        self.screen = Screen(rows, cols)
        self._rows = rows
        self._cols = cols
        self._state = "ground"
        self._queue: list[int] = []
        self._params: list[int] = []
        self._param_buf = ""
        self._private = ""
        self._intermediate = ""
        self._osc = bytearray()
        self._last_char = " "
        self._utf8_pending = bytearray()
        self._utf8_needed = 0

    def feed(self, data: bytes | bytearray | str) -> None:
        if isinstance(data, str):
            data = data.encode("utf-8", "replace")
        self._queue.extend(data)
        while self._queue:
            byte = self._queue.pop(0)
            if self._state == "utf8":
                self._utf8_pending.append(byte)
                self._utf8_needed -= 1
                if self._utf8_needed == 0:
                    self._emit_utf8(bytes(self._utf8_pending))
                    self._utf8_pending = bytearray()
                    self._state = "ground"
                continue
            if self._state == "osc_esc":
                if byte == 0x5C:
                    self._state = "ground"
                else:
                    self._osc.append(0x1B)
                    self._osc.append(byte)
                    self._state = "osc"
                continue
            self._feed_byte(byte)

    # -- byte dispatch -----------------------------------------------------

    def _feed_byte(self, byte: int) -> None:
        if self._state == "osc":
            if byte == 0x07:
                self._state = "ground"
            elif byte == 0x1B:
                self._state = "osc_esc"
            else:
                self._osc.append(byte)
            return
        if self._state == "esc":
            self._esc_byte(byte)
            return
        if self._state == "csi":
            self._csi_byte(byte)
            return
        if self._state == "charset":
            self._state = "ground"
            return
        self._ground_byte(byte)

    def _ground_byte(self, byte: int) -> None:
        sc = self.screen
        if byte == 0x1B:
            self._state = "esc"
        elif byte in (0x0A, 0x0B, 0x0C):
            sc._linefeed()
        elif byte == 0x0D:
            sc.carriage_return()
        elif byte == 0x08:
            sc.backspace()
        elif byte == 0x09:
            sc.tab()
        elif byte in C0_IGNORE:
            pass
        elif 0x20 <= byte < 0x7F:
            char = chr(byte)
            sc.put_char(char)
            self._last_char = char
        elif byte >= 0x80:
            self._utf8_pending = bytearray([byte])
            if 0xC2 <= byte <= 0xDF:
                self._utf8_needed = 1
            elif 0xE0 <= byte <= 0xEF:
                self._utf8_needed = 2
            elif 0xF0 <= byte <= 0xF4:
                self._utf8_needed = 3
            else:
                self._state = "ground"
                return
            self._state = "utf8"

    def _emit_utf8(self, raw: bytes) -> None:
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            return
        for char in text:
            self.screen.put_char(char)
            self._last_char = char

    # -- ESC sequences -----------------------------------------------------

    def _esc_byte(self, byte: int) -> None:
        if byte == 0x5B:  # '['
            self._begin_csi()
        elif byte == 0x5D:  # ']' OSC
            self._state = "osc"
            self._osc = bytearray()
        elif byte in (0x28, 0x29, 0x2A, 0x2B):  # charset select
            self._state = "charset"
        elif byte == 0x37:  # save cursor
            self.screen.save_cursor()
            self._state = "ground"
        elif byte == 0x38:  # restore cursor
            self.screen.restore_cursor()
            self._state = "ground"
        elif byte in (0x3D, 0x3E):  # keypad modes: ignored
            self._state = "ground"
        elif byte == 0x4D:  # RI
            self.screen.reverse_index()
            self._state = "ground"
        elif byte == 0x44:  # IND
            self.screen._linefeed()
            self._state = "ground"
        elif byte == 0x45:  # NEL
            self.screen.newline()
            self._state = "ground"
        elif byte == 0x5C:  # ST
            self._state = "ground"
        else:
            self._state = "ground"

    # -- CSI sequences -----------------------------------------------------

    def _begin_csi(self) -> None:
        self._state = "csi"
        self._params = []
        self._param_buf = ""
        self._private = ""
        self._intermediate = ""

    def _csi_byte(self, byte: int) -> None:
        if 0x30 <= byte <= 0x39 or byte == 0x3B:  # digits / ';'
            self._param_buf += chr(byte)
            return
        if byte in (0x3F, 0x3E, 0x21, 0x3C):  # private marker
            self._private = chr(byte)
            return
        if 0x20 <= byte <= 0x2F:  # intermediate bytes
            self._intermediate += chr(byte)
            return
        self._dispatch_csi(byte)

    def _csi_params(self, default: int = 1) -> list[int]:
        if self._param_buf == "":
            return [default]
        return [int(p) if p != "" else default for p in self._param_buf.split(";")]

    def _dispatch_csi(self, final: int) -> None:
        sc = self.screen
        final_char = chr(final)
        params = self._csi_params()
        n = params[0]
        if self._private in ("?", ">", "<", "!", "="):
            # DEC private modes, modifyOtherKeys, Kitty protocol query, DA
            # responses, cursor-style reports: no visible-screen effect.
            pass
        elif final_char == "H" or final_char == "f":
            sc.move_to(params[0], params[1] if len(params) > 1 else 1)
        elif final_char == "A":
            sc.move_up(n)
        elif final_char == "B":
            sc.move_down(n)
        elif final_char == "C":
            sc.move_right(n)
        elif final_char == "D":
            sc.move_left(n)
        elif final_char == "E":
            sc.cursor_row = min(sc.cursor_row + n, sc.rows - 1)
            sc.cursor_col = 0
        elif final_char == "F":
            sc.cursor_row = max(sc.cursor_row - n, 0)
            sc.cursor_col = 0
        elif final_char == "G" or final_char == "`":
            sc.set_column(n)
        elif final_char == "d":
            sc.set_row(n)
        elif final_char == "J":
            sc.erase_display(params[0])
        elif final_char == "K":
            sc.erase_line(params[0])
        elif final_char == "L":
            sc.insert_lines(n)
        elif final_char == "M":
            sc.delete_lines(n)
        elif final_char == "P":
            sc.delete_chars(n)
        elif final_char == "X":
            sc.erase_chars(n)
        elif final_char == "S":
            sc.scroll_up(n)
        elif final_char == "T":
            sc.scroll_down(n)
        elif final_char == "r":
            sc.set_margins(params[0], params[1] if len(params) > 1 else sc.rows)
        elif final_char == "s":
            sc.save_cursor()
        elif final_char == "u":
            sc.restore_cursor()
        elif final_char == "b":
            sc.repeat_char(n, self._last_char)
        elif final_char == "m":
            pass  # SGR: colors do not affect the normalized text screen
        else:
            pass  # DSR/DA/window ops/unknown: ignored
        self._state = "ground"

    def reset(self) -> None:
        self.__init__(self._rows, self._cols)


def main() -> int:
    failures: list[str] = []

    def check(name: str, got: object, want: object) -> None:
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    p = VTParser(3, 8)
    p.feed(b"abc")
    check("basic text", p.screen.visible_rows(), ["abc", "", ""])
    check("cursor col", p.screen.cursor_col, 3)

    p = VTParser(3, 8)
    p.feed(b"abcdefgh\x1b[2K\rX")
    check("erase line then CR", p.screen.visible_rows(), ["X", "", ""])

    p = VTParser(3, 8)
    p.feed(b"12345678\r\nabc")
    check("CRLF", p.screen.visible_rows(), ["12345678", "abc", ""])

    p = VTParser(3, 8)
    p.feed(b"ab\r\x1b[1G\x1b[2K\r\x1b[1GX")
    check("rewrite full line", p.screen.visible_rows(), ["X", "", ""])

    p = VTParser(3, 8)
    p.feed(b"a\x1b[1Bb")
    check("CUD", p.screen.cursor_row, 1)

    p = VTParser(3, 8)
    p.feed(b"a\x1b[2;3Hb")
    check("CUP", p.screen.cursor_row, 1)
    check("CUP col", p.screen.cursor_col, 3)

    p = VTParser(3, 8)
    p.feed(b"ab\x1b[Dc")
    check("CUB", p.screen.visible_rows(), ["ac", "", ""])

    p = VTParser(3, 8)
    p.feed(b"abc\x1b[2J\x1b[Hxy")
    check("erase display", p.screen.visible_rows(), ["xy", "", ""])

    p = VTParser(3, 8)
    p.feed(b"abc\x1b[s\x1b[2;2Hxy\x1b[u!")
    check("save/restore cursor", p.screen.visible_rows(), ["abc!", " xy", ""])

    p = VTParser(3, 8)
    p.feed(b"\x1b[?2026h\x1b[38;2;80;80;80m\x1b[39mab\x1b]8;;http://x\x07cd\x1b]8;;\x1b\\ef")
    check("modes, SGR, OSC 8", p.screen.visible_rows(), ["abcdef", "", ""])

    p = VTParser(3, 8)
    p.feed(b"abc\r\n\x1b[2K\rX")
    check("erase across lines", p.screen.visible_rows(), ["abc", "X", ""])

    p = VTParser(3, 8)
    p.feed(b"\x1b[>1u\x1b[?u\x1b[c")
    check("kitty query + DA ignored", p.screen.visible_rows(), ["", "", ""])

    p = VTParser(3, 8)
    p.feed("你".encode("utf-8"))
    check("wide char two cells", p.screen.cursor_col, 2)
    check("wide char visible", p.screen.visible_rows()[0], "你")

    p = VTParser(3, 8)
    p.feed("ab你c".encode("utf-8"))
    check("mixed width col", p.screen.cursor_col, 5)

    p = VTParser(3, 8)
    p.feed(b"a\x1b[3b")
    check("REP", p.screen.visible_rows(), ["aaaa", "", ""])

    p = VTParser(4, 8)
    p.feed(b"l1\x1b[2K\rl2\x1b[2K\rl3")
    check("progressive rewrite", p.screen.visible_rows(), ["l3", "", "", ""])

    p = VTParser(4, 8)
    p.feed(b"\x1b[2;3r" + b"".join(b"row%d\r\n" % i for i in range(6)))
    check("scroll margins row0 untouched", p.screen.visible_rows()[0], "row0")
    check("scroll margins scrolled in", p.screen.visible_rows()[1], "row5")
    check("scroll margins latest row", p.screen.visible_rows()[2], "")

    p = VTParser(3, 8)
    p.feed(b"ab\x1b[2;2H\x1b[K")
    check("EL clears row", p.screen.visible_rows(), ["ab", "", ""])

    p = VTParser(3, 8)
    p.feed(b"abc\x1b[2;2H\x1b[2K")
    check("EL2", p.screen.visible_rows(), ["abc", "", ""])

    p = VTParser(3, 8)
    p.feed("a" + "\U0001f600" + "b")
    check("emoji width", p.screen.cursor_col, 4)

    if failures:
        print("vt_screen self-test FAILED:")
        for failure in failures:
            print(" -", failure)
        return 1
    print("vt_screen self-test OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
