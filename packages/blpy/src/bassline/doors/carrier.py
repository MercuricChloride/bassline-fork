"""The kind-tagged JSON carrier (:mod:`bassline.carrier`), as a door.

The carrier holds any value inside JSON and refuses anything that isn't
one, so it carries values through JSON-only channels without loss. A
document is one or more JSON texts in a row, each a carrier value or an
array of carrier values (as ``corpus/corpus.json`` is). The writer writes
each value as one line of carrier JSON.
"""

from __future__ import annotations

import json as _json
from collections.abc import Iterator
from typing import Any

from .. import carrier as _carrier
from ..errors import NotHeld
from ..values import Value
from ._door import Door, TextWriter, text_of, utf8_or_none
from .json import texts

__all__ = ["door", "read", "loads", "dumps", "writer", "sure"]

_DECODER = _json.JSONDecoder(parse_int=_carrier._parse_int,
                             parse_float=_carrier._parse_float,
                             parse_constant=_carrier._parse_float,
                             object_pairs_hook=_carrier._pairs)


def _values(text: str) -> Iterator[Value]:
    for tree in texts(text, _DECODER):
        if isinstance(tree, list):
            for node in tree:
                yield _carrier.from_carrier(node)
        else:
            yield _carrier.from_carrier(tree)


class CarrierDoor(Door):
    name = "carrier"
    summary = "the kind-tagged JSON carrier: any value inside JSON, exactly"
    extensions = (".carrier.json",)
    readings = ("carrier",)
    writers = ("carrier",)

    def sure(self, data: bytes | str) -> int:
        text = utf8_or_none(data)
        if text is None or "kind" not in text:
            return 0
        try:
            found = sum(1 for _ in _values(text)) > 0
        except NotHeld:
            return 0
        return 92 if found else 0

    def _read(self, data, reading) -> Iterator[Value]:
        return _values(text_of(data, "carrier JSON"))

    def _writer(self, out: Any, name: str) -> TextWriter:
        return TextWriter(out, lambda v: _carrier.to_json(v) + "\n")


door = CarrierDoor()
read = door.read
loads = door.loads
dumps = door.dumps
writer = door.writer
sure = door.sure
