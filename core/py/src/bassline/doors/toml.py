"""TOML, read with the standard library's ``tomllib``.

The first pass: tables are dicts with text keys, arrays lists, strings
text, integers integers, ``true`` and ``false`` the symbols. A float is
read from its spelling, exactly: ``1.50`` is ``(dec 150 -2)`` (underscores
between digits and a leading ``+`` mean nothing in TOML and are dropped).
``inf``, ``nan`` and ``-0.0`` have no ``dec`` form and are kept as
``(number "inf")`` and so on. Dates and times are records, never text a
later reader has to guess at: ``(date 1979 5 27)``, ``(time 7 32 0)``,
``(datetime (date 1979 5 27) (time 0 32 0) (offset -420))``. A fraction of
a second keeps every digit written, ``00.500`` as ``(dec 500 -3)``:
``tomllib`` keeps only microseconds, so the digits are found in the source.

The writer is minimal: a value must be a dict (a TOML document is a
table), nested dicts become ``[tables]``, everything else is written
inline. TOML has no nil and its integers are 64-bit, so the writer
refuses those; ``(dec m e)`` is written as a float spelled exactly, the
date and time records as TOML's own, symbols and bytes (``"0x…"``) as
strings, sets as arrays, other records as arrays with the head first.
"""

from __future__ import annotations

import datetime as _dt
import re
import tomllib
from collections.abc import Iterator
from typing import Any

from ..errors import NotHeld
from ..text import to_text
from ..values import Dict, Integer, Kind, List, Text, Value, rec
from . import _vocab
from ._door import Door, TextWriter, spelled_keys, text_of, utf8_or_none

__all__ = ["door", "read", "loads", "dumps", "writer", "sure"]


def _float(spelling: str) -> Value:
    s = spelling.replace("_", "")
    v = _vocab.number(s[1:] if s.startswith("+") else s)
    return v if v is not None else rec(_vocab.NUMBER, Text(s))


# A time's fraction of a second, outside strings and comments: tomllib keeps
# only microseconds, so the digits as written are found in the source.
_FRACTIONS = re.compile(
    r'''(?P<skip>"""(?:[^\\]|\\.)*?"""|\'\'\'.*?\'\'\'|"(?:[^"\\\n]|\\.)*"|'[^'\n]*'|\#[^\n]*)'''
    r"|(?<![0-9:.])(?P<h>[0-9]{2}):(?P<m>[0-9]{2}):(?P<s>[0-9]{2})\.(?P<f>[0-9]+)", re.S)


def _fractions(text: str) -> dict[tuple[int, int, int, int], set[str]]:
    """Each fraction spelled in the document, by the time tomllib reads it
    as: (hour, minute, second, microsecond)."""
    found: dict[tuple[int, int, int, int], set[str]] = {}
    for m in _FRACTIONS.finditer(text):
        if m.group("f") is not None:
            f = m.group("f")
            key = (int(m.group("h")), int(m.group("m")), int(m.group("s")), int(f[:6].ljust(6, "0")))
            found.setdefault(key, set()).add(f)
    return found


def _conv(x: Any, fractions: dict) -> Value:
    if isinstance(x, Value):
        return x
    if isinstance(x, bool):
        return _vocab.TRUE if x else _vocab.FALSE
    if isinstance(x, int):
        return Integer(x)
    if isinstance(x, str):
        return Text(x)
    if isinstance(x, dict):
        return Dict((Text(k), _conv(v, fractions)) for k, v in x.items())
    if isinstance(x, list):
        return List._trusted(tuple(_conv(m, fractions) for m in x))
    if isinstance(x, _dt.time) or isinstance(x, _dt.datetime):
        fraction = ""
        if x.microsecond:
            spelled = fractions.get((x.hour, x.minute, x.second, x.microsecond), set())
            if len(spelled) > 1:
                raise NotHeld(f"the time {x.isoformat()} is spelled with fractions "
                              f"{' and '.join(sorted(spelled))}; which is which can't be told")
            fraction = spelled.pop() if spelled else f"{x.microsecond:06d}"
        return _vocab.date_value(x, fraction)
    if isinstance(x, _dt.date):
        return _vocab.date_value(x)
    raise NotHeld(f"no reading of TOML's {type(x).__name__}")  # pragma: no cover


# ---------------------------------------------------------------- writing

_BARE = re.compile(r"[A-Za-z0-9_-]+\Z")
_ESCAPES = {"\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r",
            '"': '\\"', "\\": "\\\\"}
_TOML_FLOAT = re.compile(r"[-+]?(inf|nan)\Z|[-+]?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?\Z")
_INT64 = range(-2**63, 2**63)


def _string(s: str) -> str:
    out = ['"']
    for c in s:
        e = _ESCAPES.get(c)
        if e is not None:
            out.append(e)
        elif c < " " or c == "\x7f":
            out.append(f"\\u{ord(c):04x}")
        else:
            out.append(c)
    out.append('"')
    return "".join(out)


def _key(k: Value) -> str:
    name = k.value if k.kind in (Kind.TEXT, Kind.SYMBOL) else to_text(k)
    return name if _BARE.match(name) else _string(name)


def _inline(v: Value) -> str:
    k = v.kind
    if k == Kind.NIL:
        raise NotHeld("TOML has no nil")
    if k == Kind.INTEGER:
        if v.value not in _INT64:
            raise NotHeld(f"TOML's integers are 64-bit, and {v.spelling} isn't")
        return v.spelling
    if k == Kind.TEXT:
        return _string(v.value)
    if k == Kind.SYMBOL:
        return v.name if v.name in ("true", "false") else _string(v.name)
    if k == Kind.BYTES:
        return _string("0x" + v.value.hex())
    if k in (Kind.LIST, Kind.SET):
        return "[" + ", ".join(_inline(m) for m in v) + "]"
    if k == Kind.DICT:
        if not v:
            return "{}"
        return "{ " + ", ".join(f"{a} = {_inline(b)}" for a, b in spelled_keys(v, _key, "TOML")) + " }"
    s = _vocab.spelling(v)
    if s is not None and _TOML_FLOAT.match(s):
        if "." not in s and "e" not in s.lower() and s.lstrip("+-") not in ("inf", "nan"):
            s += ".0"   # an integral (number "...") spelling, kept a float
        return s
    if _vocab.date_kind(v) is not None:
        return _vocab.iso(v)
    s = _vocab.iso(v)
    if s is not None:
        return _string(s)
    return "[" + ", ".join(_inline(m) for m in v) + "]"


def _table(d: Value, path: list[str], out: list[str]) -> None:
    subtables = []
    for k, v in spelled_keys(d, _key, "TOML"):
        if v.kind == Kind.DICT:
            subtables.append((k, v))
        else:
            out.append(f"{k} = {_inline(v)}\n")
    for k, v in subtables:
        sub = path + [k]
        if out:
            out.append("\n")
        out.append(f"[{'.'.join(sub)}]\n")
        _table(v, sub, out)


class _Render:
    def __init__(self):
        self.written = False

    def __call__(self, v: Value) -> str:
        if v.kind != Kind.DICT:
            raise NotHeld(f"a TOML document is a table, a dict; not {to_text(v)[:60]}")
        if self.written:
            raise NotHeld("a TOML document is one table, and one has been written")
        out: list[str] = []
        _table(v, [], out)
        self.written = True
        return "".join(out)


class TOMLDoor(Door):
    name = "toml"
    summary = "TOML: tables as dicts, dates and times as records"
    extensions = (".toml",)
    readings = ("toml",)
    writers = ("toml",)

    def sure(self, data: bytes | str) -> int:
        text = utf8_or_none(data)
        if not text or not text.strip():
            return 0
        try:
            doc = tomllib.loads(text)
        except (tomllib.TOMLDecodeError, ValueError):
            return 0
        return 70 if doc else 10

    def _read(self, data, reading) -> Iterator[Value]:
        text = text_of(data, "TOML")
        try:
            doc = tomllib.loads(text, parse_float=_float)
        except tomllib.TOMLDecodeError as e:
            raise NotHeld(f"not TOML: {e}") from None
        except ValueError as e:   # an integer past what int() will spell
            raise NotHeld(f"not held: {e}") from None
        return iter((_conv(doc, _fractions(text)),))

    def _writer(self, out: Any, name: str) -> TextWriter:
        return TextWriter(out, _Render())


door = TOMLDoor()
read = door.read
loads = door.loads
dumps = door.dumps
writer = door.writer
sure = door.sure
