"""CSV: a table as a list of rows, each a list of text cells.

Everything is text and nothing is guessed: ``007`` stays the text
``"007"``, an empty cell is the empty text. Levers do the rest (``header``,
``numbers``). Quoting follows RFC 4180: a quoted cell may hold commas,
quotes (doubled) and line breaks. A quote after a closing quote, or a
quoted cell the document never closes, is refused rather than read some way
the document didn't say; a quote inside an unquoted cell (``a"b``) is part
of that cell. A blank line is an empty row.

The writer takes a table (a list of rows) or a row on its own. A row is a
list or record of cells, or a dict; dict rows share a header row, the union
of their keys in the order first seen, which the writer puts first. Cells
are written as text: integers and ``dec`` spelled, symbols by name, nil as
an empty cell, anything else in the textual syntax.
"""

from __future__ import annotations

import csv as _csv
import io
from collections.abc import Iterator
from itertools import islice
from typing import Any

from ..errors import NotHeld
from ..text import to_text
from ..values import Kind, List, Text, Value
from . import _vocab
from ._door import Door, TextWriter, text_of, utf8_or_none

__all__ = ["door", "read", "loads", "dumps", "writer", "sure", "CSVDoor"]


def _cell(v: Value) -> str:
    k = v.kind
    if k in (Kind.TEXT, Kind.SYMBOL):
        return v.value
    if k == Kind.NIL:
        return ""
    s = _vocab.spelling(v)
    if s is not None:
        return s
    if k == Kind.BYTES:
        return "0x" + v.value.hex()
    s = _vocab.iso(v)
    return s if s is not None else to_text(v)


def _is_row(v: Value) -> bool:
    return v.kind in (Kind.LIST, Kind.RECORD, Kind.DICT)


class _TableWriter:
    """Renders values as CSV text. A dict row's header is written once, by
    the first table or row that has dicts; a later dict row with a key the
    header lacks is refused, since the header is already out."""

    def __init__(self, door: CSVDoor):
        self.door = door
        self.header: list[Value] | None = None

    def __call__(self, v: Value) -> str:
        if v.kind == Kind.LIST and len(v) and all(_is_row(r) for r in v):
            rows = list(v)
        elif _is_row(v):
            rows = [v]
        else:
            raise NotHeld(f"{self.door.name.upper()} holds a table, a list of rows; "
                          f"not {to_text(v)[:60]}")
        out = io.StringIO()
        w = self.door._writer_for(out)
        dict_rows = [r for r in rows if r.kind == Kind.DICT]
        if dict_rows and self.header is None:
            seen: dict[Value, None] = {}
            for r in dict_rows:
                seen.update(dict.fromkeys(r.keys()))
            self.header = list(seen)
            names = [_cell(k) for k in self.header]
            if len(set(names)) != len(names):
                twice = next(k for k, n in zip(self.header, names) if names.count(n) > 1)
                raise NotHeld(f"two keys would both be the column {_cell(twice)!r}, "
                              "which a header can't hold apart")
            self._row(w, names)
        for r in rows:
            if r.kind == Kind.DICT:
                missing = [k for k in r.keys() if k not in self.header]
                if missing:
                    raise NotHeld(f"a row has the key {missing[0]}, which the header "
                                  "written before it lacks")
                cells = [_cell(r[k]) if k in r else "" for k in self.header]
            else:
                cells = [_cell(c) for c in r]
            self._row(w, cells)
        return out.getvalue()

    def _row(self, w, cells: list[str]) -> None:
        try:
            w.writerow(cells)
        except _csv.Error as e:
            raise NotHeld(f"{self.door.name.upper()} can't hold that cell: {e}") from None


class CSVDoor(Door):
    name = "csv"
    summary = "comma-separated values: rows of text cells, nothing guessed"
    extensions = (".csv",)
    readings = ("csv",)
    writers = ("csv",)
    delimiter = ","

    def _reader(self, text: str):
        return _csv.reader(io.StringIO(text, newline=""), delimiter=self.delimiter,
                           strict=True)

    def _writer_for(self, out):
        return _csv.writer(out, delimiter=self.delimiter, lineterminator="\n")

    def sure(self, data: bytes | str) -> int:
        text = utf8_or_none(data)
        if not text or not text.strip():
            return 0
        try:
            rows = [r for r in islice(self._reader(text), 200) if r]
        except _csv.Error:
            return 0
        widths = {len(r) for r in rows}
        if not rows or max(widths) < 2:
            return 5
        if len(widths) > 1:
            return 10
        if len(rows) == 1:
            return 15   # one line with commas in it is as likely prose
        # a tab rarely separates cells by accident, so TSV edges out CSV
        return 62 if self.delimiter == "\t" else 60

    def _read(self, data, reading) -> Iterator[Value]:
        text = text_of(data, self.name.upper())
        reader = self._reader(text)
        rows = []
        try:
            for row in reader:
                rows.append(List._trusted(tuple(Text(c) for c in row)))
        except _csv.Error as e:
            raise NotHeld(f"not {self.name.upper()}: {e} (line {reader.line_num})") from None
        return iter((List._trusted(tuple(rows)),))

    def _writer(self, out: Any, name: str) -> TextWriter:
        return TextWriter(out, _TableWriter(self))


door = CSVDoor()
read = door.read
loads = door.loads
dumps = door.dumps
writer = door.writer
sure = door.sure
