"""The canonical encoding itself: a bare concatenation of CE (a ``.blb``).

The richest door there is, since CE is what a value is. Reading refuses
bytes that break a rule, naming the corpus reason, and input that stops
partway through a value; writing is :func:`bassline.edge.ce_writer`.
"""

from __future__ import annotations

import codecs
from collections.abc import Iterator
from typing import Any

from ..codec import DEFAULT_MAX_VALUE_BYTES, Decoder, iterdecode
from ..edge import CEWriter
from ..errors import DecodeError, Incomplete
from ..values import Value, _read
from ._door import Door

__all__ = ["door", "read", "loads", "dumps", "writer", "sure", "stream_head"]


def _utf8_so_far(data: bytes) -> bool:
    """Whether ``data`` could be the start of UTF-8 text."""
    try:
        codecs.getincrementaldecoder("utf-8")().decode(data, final=False)
    except UnicodeDecodeError:
        return False
    return True


def stream_head(data: bytes) -> str:
    """What the start of a live stream says about being CE, before the
    stream has ended: ``"ce"`` when it is a well-formed start of CE that
    can't be text (CE's frames close with a byte UTF-8 never begins with,
    so almost every stream of values shows it within its first value),
    ``"not"`` when the bytes break a rule, and ``"undecided"`` otherwise."""
    d = Decoder(max_value_bytes=max(DEFAULT_MAX_VALUE_BYTES, len(data)))
    try:
        for _ in d.feed(data):
            pass
    except DecodeError:
        return "not"
    return "undecided" if _utf8_so_far(data) else "ce"


class CEDoor(Door):
    name = "ce"
    summary = "the canonical encoding: a bare concatenation of values (.blb)"
    extensions = (".blb",)
    readings = ("ce",)
    writers = ("ce",)

    def sure(self, data: bytes | str) -> int:
        if isinstance(data, str) or not data:
            return 0
        data = bytes(data)
        d = Decoder(max_value_bytes=max(DEFAULT_MAX_VALUE_BYTES, len(data)))
        try:
            for _ in d.feed(data):
                pass
            for _ in d.finish():
                pass
            whole = True
        except Incomplete:
            whole = False
        except DecodeError:
            return 0
        text = _utf8_so_far(data)
        if whole:
            # values with frames close with END, which no UTF-8 text holds;
            # a few atoms can spell ordinary text by accident
            return 60 if text else 95
        return 15 if text else 50

    def _read(self, data, reading) -> Iterator[Value]:
        if isinstance(data, str):
            raise TypeError("CE is bytes, not str")
        data = bytes(data)
        return iterdecode([data], max_value_bytes=max(DEFAULT_MAX_VALUE_BYTES, len(data)))

    def _writer(self, out: Any, name: str) -> CEWriter:
        return CEWriter(out)

    def dumps(self, value: Any, name: str | None = None) -> bytes:
        return _read(value).ce


door = CEDoor()
read = door.read
loads = door.loads
dumps = door.dumps
writer = door.writer
sure = door.sure
