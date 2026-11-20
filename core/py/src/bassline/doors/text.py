"""The textual syntax (``.bl``): bassline's human form.

Reading takes a whole document (comments are not values and are dropped);
writing lays each value out within 80 columns, one after another.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

from ..errors import Incomplete, Refused
from ..text import pretty, read_all
from ..values import Value
from ._door import Door, TextWriter, text_of, utf8_or_none

__all__ = ["door", "read", "loads", "dumps", "writer", "sure"]


class TextDoor(Door):
    name = "text"
    summary = "the textual syntax, for people (.bl)"
    extensions = (".bl", ".blt")
    readings = ("text",)
    writers = ("text",)

    def __init__(self, width: int = 80):
        self.width = width

    def sure(self, data: bytes | str) -> int:
        text = utf8_or_none(data)
        if not text or not text.strip():
            return 0
        try:
            values = read_all(text)
        except (Refused, Incomplete):
            return 0
        if not values:
            return 0
        if any(v.is_frame for v in values) or len(values) <= 2:
            return 40
        return 15   # a run of loose words and numbers reads like prose, not values

    def _read(self, data, reading) -> Iterator[Value]:
        return iter(read_all(text_of(data, "the textual syntax")))

    def _writer(self, out: Any, name: str) -> TextWriter:
        return TextWriter(out, lambda v: pretty(v, self.width) + "\n")


door = TextDoor()
read = door.read
loads = door.loads
dumps = door.dumps
writer = door.writer
sure = door.sure
