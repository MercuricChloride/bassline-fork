"""Ordinary JSON.

The first pass keeps everything a JSON document says:

- objects are dicts with text keys, arrays lists, strings text, ``null``
  nil, ``true`` and ``false`` the symbols ``true`` and ``false``;
- numbers are read from their spelling in the source, never through a
  float: ``12345678901234567890123456789`` is that integer, ``1.50`` is
  ``(dec 150 -2)``, ``1E+2`` is ``(dec 1 2)``. A negative zero (``-0``,
  ``-0.0``) has no integer or ``dec`` form and is kept as
  ``(number "-0")``, never read as ``0``;
- ``NaN`` and ``Infinity`` are not JSON and are refused, and so is a lone
  surrogate escape (``"\\ud800"``), which has no UTF-8 form;
- an object that gives a key twice can't be a dict, so the ``json``
  reading refuses it; the ``json-entries`` reading reads every object as
  ``(object ["key" value] …)``, keeping member order and repeated keys.

A document may be several JSON texts in a row, separated by whitespace
(JSON Lines among them): each is one value.

The writers: ``json`` writes each value indented, ``jsonl`` each on one
line. Integers and ``(dec m e)`` are written as numbers spelled exactly,
symbols as strings (``true`` and ``false`` as JSON's), bytes as ``"0x…"``,
sets as arrays, ``(object [k v] …)`` as an object with those members in
order, dates and times as ISO 8601 strings, and other records as arrays
with the head first. Marks are dropped.
"""

from __future__ import annotations

import json as _json
import re
from collections.abc import Iterator
from typing import Any

from ..errors import NotHeld
from ..text import to_text
from ..values import Dict, Kind, List, Text, Value, nil, rec, sym
from . import _vocab
from ._door import Door, TextWriter, spelled_keys, text_of, utf8_or_none

__all__ = ["door", "read", "loads", "dumps", "writer", "sure", "texts"]

OBJECT = sym.object
_WS = re.compile(r"[ \t\n\r]*")


def texts(text: str, decoder: _json.JSONDecoder) -> Iterator[Any]:
    """Each JSON text in ``text``, parsed by ``decoder``: one, or several
    separated by whitespace."""
    i = _WS.match(text).end()
    n = len(text)
    while i < n:
        try:
            tree, j = decoder.raw_decode(text, i)
        except _json.JSONDecodeError as e:
            raise NotHeld(f"not JSON: {e.msg} at line {e.lineno} column {e.colno}") from None
        except RecursionError:
            raise NotHeld("nested deeper than Python's JSON parser can follow") from None
        yield tree
        i = _WS.match(text, j).end()
        if i == j and i < n:
            line = text.count("\n", 0, i) + 1
            col = i - (text.rfind("\n", 0, i) + 1) + 1
            raise NotHeld(f"not JSON: extra data at line {line} column {col}")


def _int(s: str) -> Value:
    return _vocab.number(s)


def _float(s: str) -> Value:
    return _vocab.number(s)


def _constant(s: str):
    raise NotHeld(f"{s} is not JSON, and no number holds it")


def _conv(x: Any) -> Value:
    if isinstance(x, Value):
        return x
    if x is True:
        return _vocab.TRUE
    if x is False:
        return _vocab.FALSE
    if x is None:
        return nil
    if isinstance(x, str):
        return Text(x)
    return List._trusted(tuple(_conv(m) for m in x))


def _dict(pairs: list) -> Value:
    d: dict = {}
    for k, v in pairs:
        key = Text(k)
        if key in d:
            raise NotHeld(f"the key {key} appears twice in one object; a dict holds "
                          "each key once (the json-entries reading keeps both)")
        d[key] = _conv(v)
    return Dict(d)


def _entries(pairs: list) -> Value:
    return rec(OBJECT, *(List._trusted((Text(k), _conv(v))) for k, v in pairs))


def _decoder(object_hook) -> _json.JSONDecoder:
    return _json.JSONDecoder(parse_int=_int, parse_float=_float,
                             parse_constant=_constant, object_pairs_hook=object_hook)


_SYNTAX = _json.JSONDecoder(parse_int=lambda s: 0, parse_float=lambda s: 0,
                            parse_constant=_constant, object_pairs_hook=lambda p: 0)

# ---------------------------------------------------------------- writing

_JSON_NUMBER = re.compile(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?\Z")


def _string(s: str) -> str:
    return _json.dumps(s, ensure_ascii=False)


def _key(k: Value) -> str:
    if k.kind in (Kind.TEXT, Kind.SYMBOL):
        return k.value
    if k.kind == Kind.INTEGER:
        return k.spelling
    return to_text(k)


def _object_entries(v: Value) -> list | None:
    """The members of ``(object [k v] …)``, if ``v`` is one."""
    if v.head != OBJECT:
        return None
    out = []
    for f in v.fields:
        if f.kind != Kind.LIST or len(f) != 2:
            return None
        out.append((f[0], f[1]))
    return out


def _number(v: Value) -> str | None:
    s = _vocab.spelling(v)
    return s if s is not None and _JSON_NUMBER.match(s) else None


def _emit(v: Value, out: list, indent: int | None, depth: int) -> None:
    k = v.kind
    if k == Kind.NIL:
        out.append("null")
    elif k == Kind.INTEGER:
        out.append(v.spelling)
    elif k == Kind.TEXT:
        out.append(_string(v.value))
    elif k == Kind.SYMBOL:
        out.append(v.name if v.name in ("true", "false") else _string(v.name))
    elif k == Kind.BYTES:
        out.append('"0x' + v.value.hex() + '"')
    elif k == Kind.DICT:
        _members(spelled_keys(v, _key, "JSON"), True, out, indent, depth)
    elif k in (Kind.LIST, Kind.SET):
        _members(v, False, out, indent, depth)
    else:
        s = _number(v)
        if s is not None:
            out.append(s)
            return
        entries = _object_entries(v)
        if entries is not None:
            _members(((_key(a), b) for a, b in entries), True, out, indent, depth)
            return
        s = _vocab.iso(v)
        if s is not None:
            out.append(_string(s))
            return
        _members(v, False, out, indent, depth)


def _members(items, keyed: bool, out: list, indent: int | None, depth: int) -> None:
    opener, closer = ("{", "}") if keyed else ("[", "]")
    out.append(opener)
    first = True
    pad = "" if indent is None else "\n" + " " * (indent * (depth + 1))
    for item in items:
        if not first:
            out.append(",")
            if indent is None:
                out.append(" ")
        out.append(pad)
        first = False
        if keyed:
            out.append(_string(item[0]))
            out.append(": ")
            _emit(item[1], out, indent, depth + 1)
        else:
            _emit(item, out, indent, depth + 1)
    if not first and indent is not None:
        out.append("\n" + " " * (indent * depth))
    out.append(closer)


def to_json(v: Value, indent: int | None = 2) -> str:
    """``v`` as ordinary JSON text (lossy; see the module notes)."""
    out: list[str] = []
    _emit(v, out, indent, 0)
    return "".join(out)


class JSONDoor(Door):
    name = "json"
    summary = "ordinary JSON, one text or several in a row (JSON Lines)"
    extensions = (".json", ".jsonl", ".ndjson")
    readings = ("json", "json-entries")
    writers = ("json", "jsonl")
    extension_writers = {".jsonl": "jsonl", ".ndjson": "jsonl"}

    def sure(self, data: bytes | str) -> int:
        text = utf8_or_none(data)
        if text is None:
            return 0
        start = _WS.match(text).end()
        if start == len(text):
            return 0
        try:
            for _ in texts(text, _SYNTAX):
                pass
        except NotHeld:
            return 0
        return 90 if text[start] in "{[" else 65

    def _read(self, data, reading) -> Iterator[Value]:
        text = text_of(data, "JSON")
        decoder = _decoder(_entries if reading == "json-entries" else _dict)
        return (_conv(tree) for tree in texts(text, decoder))

    def _writer(self, out: Any, name: str) -> TextWriter:
        indent = None if name == "jsonl" else 2
        return TextWriter(out, lambda v: to_json(v, indent) + "\n")


door = JSONDoor()
read = door.read
loads = door.loads
dumps = door.dumps
writer = door.writer
sure = door.sure
