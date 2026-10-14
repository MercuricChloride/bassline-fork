"""The JSON carrier: bassline values inside JSON, and nothing else.

Each value is an object ``{"kind": K, "mark": true, "value": V}``, with
``"mark"`` present only when set and ``"value"`` absent for nil:

========  ===============================================================
kind      value
========  ===============================================================
nil       (none)
number    a JSON integer, of any width
text      a string
symbol    a string
bytes     a ``0x``-prefixed hex string
list      an array of values
record    an array of values, head first
dict      an array of ``[key, value]`` pairs
set       an array of values
========  ===============================================================

This is a carrier, not a door for ordinary JSON: it holds any value and
refuses anything that isn't one (:class:`NotHeld`): a number that isn't an
integer's spelling, ``-0``, an unknown key, a repeated key or member, a
lone surrogate. It is never canonical: dict and set members may arrive in
any order, and a value's only identity is its CE bytes. Integers of any
width are read and written exactly, past Python's int-to-str digit limit.
"""

from __future__ import annotations

import json
from typing import Any

from .errors import NotHeld
from .values import (
    Bytes,
    Dict,
    Integer,
    Kind,
    List,
    Nil,
    Record,
    Set,
    Symbol,
    Text,
    Value,
    _ce_key,
    _parse,
    is_canonical_spelling,
)

__all__ = ["to_json", "from_json", "to_carrier", "from_carrier", "load_tree", "KIND_NAMES"]

#: The carrier's name for each kind.
KIND_NAMES = {
    Kind.NIL: "nil", Kind.INTEGER: "number", Kind.TEXT: "text",
    Kind.SYMBOL: "symbol", Kind.BYTES: "bytes", Kind.LIST: "list",
    Kind.RECORD: "record", Kind.DICT: "dict", Kind.SET: "set",
}
_KINDS = {name: kind for kind, name in KIND_NAMES.items()}
_KEYS = frozenset(("kind", "mark", "value"))


def _parse_int(s: str) -> int:
    if not is_canonical_spelling(s.encode("ascii", "replace")):
        raise NotHeld(f"not an integer's one spelling in the carrier: {s}")
    return _parse(s)


def _parse_float(s: str):
    raise NotHeld(f"not an integer in the carrier: {s}")


def _pairs(pairs: list[tuple[str, Any]]) -> dict:
    out = {}
    for k, v in pairs:
        if k in out:
            raise NotHeld(f"a carrier object repeats the key {k!r}")
        out[k] = v
    return out


def load_tree(source: str | bytes) -> Any:
    """Parse JSON text the way the carrier needs it: integers of any width
    kept exact, and floats, ``NaN``, ``-0``, a leading ``+`` and repeated
    object keys refused. Gives the plain tree, for :func:`from_carrier` (or
    for an array of carrier values, one at a time)."""
    try:
        return json.loads(source, parse_int=_parse_int, parse_float=_parse_float,
                          parse_constant=_parse_float, object_pairs_hook=_pairs)
    except json.JSONDecodeError as e:
        raise NotHeld(f"not JSON: {e}") from None
    except RecursionError:
        raise NotHeld("nested deeper than Python's JSON parser can follow") from None


def from_json(source: str | bytes) -> Value:
    """A value from carrier JSON text."""
    return from_carrier(load_tree(source))


def _members(node: Any, what: str) -> list:
    if not isinstance(node, list):
        raise NotHeld(f"a {what}'s value is an array")
    return node


def _hex(s: Any) -> bytes:
    if not isinstance(s, str) or not s.startswith("0x"):
        raise NotHeld(f"bytes are a 0x-prefixed hex string, not {s!r}")
    body = s[2:]
    if len(body) % 2 or any(c not in "0123456789abcdefABCDEF" for c in body):
        raise NotHeld(f"not an even run of hex digits: {s!r}")
    return bytes.fromhex(body)


def from_carrier(tree: Any) -> Value:
    """A value from an already-parsed carrier tree (``dict``/``list``/
    ``str``/``int``/``bool`` as ``json.loads`` gives them)."""
    # explicit stack: (node, kind, mark, members-so-far, children-to-read)
    root: list = []
    stack: list = [(None, None, None, root, iter((tree,)))]
    while True:
        frame = stack[-1]
        child = next(frame[4], _DONE)
        if child is _DONE:
            stack.pop()
            _, kind, mark, members, _ = frame
            if kind is None:
                return members[0]
            v = _build_frame(kind, mark, members)
            parent = stack[-1]
            parent[3].append(v)
            continue
        if isinstance(frame[1], Kind) and frame[1] == Kind.DICT:
            # a pair: read both, and collect them flat
            if not isinstance(child, list) or len(child) != 2:
                raise NotHeld("a dict entry is a [key, value] pair")
            stack.append((None, _PAIR, False, [], iter(child)))
            continue
        kind, mark, value = _header(child)
        if kind < 6:
            frame[3].append(_atom(kind, mark, value))
        else:
            stack.append((child, kind, mark, [], iter(_members(value, KIND_NAMES[kind]))))


_DONE = object()
_PAIR = "pair"


def _header(node: Any) -> tuple[Kind, bool, Any]:
    if not isinstance(node, dict):
        raise NotHeld(f"a carrier value is an object, not {type(node).__name__}")
    extra = set(node) - _KEYS
    if extra:
        raise NotHeld(f"unknown key in a carrier value: {sorted(extra)[0]!r}")
    name = node.get("kind")
    if not isinstance(name, str) or name not in _KINDS:
        raise NotHeld(f"not a value kind: {name!r}")
    kind = _KINDS[name]
    mark = node.get("mark", False)
    if not isinstance(mark, bool):
        raise NotHeld("\"mark\" is true or false")
    if kind == Kind.NIL:
        if "value" in node:
            raise NotHeld("nil carries no value")
        return kind, mark, None
    if "value" not in node:
        raise NotHeld(f"a {name} needs a value")
    return kind, mark, node["value"]


def _atom(kind: Kind, mark: bool, value: Any) -> Value:
    if kind == Kind.NIL:
        return Nil(mark=mark)
    if kind == Kind.INTEGER:
        if isinstance(value, bool) or not isinstance(value, int):
            raise NotHeld(f"a number's value is a JSON integer, not {value!r}")
        return Integer(value, mark=mark)
    if kind == Kind.TEXT or kind == Kind.SYMBOL:
        if not isinstance(value, str):
            raise NotHeld(f"a {KIND_NAMES[kind]}'s value is a string")
        return (Text if kind == Kind.TEXT else Symbol)(value, mark=mark)
    return Bytes(_hex(value), mark=mark)


def _build_frame(kind, mark: bool, members: list) -> Value:
    if kind == _PAIR:
        return _Pair(members)
    if kind == Kind.LIST:
        return List._trusted(tuple(members), mark)
    if kind == Kind.RECORD:
        if not members:
            raise NotHeld("a record needs a head")
        return Record._trusted(tuple(members), mark)
    if kind == Kind.SET:
        uniq = dict.fromkeys(members)
        if len(uniq) != len(members):
            raise NotHeld("a set repeats a member")
        return Set._trusted(sorted(uniq, key=_ce_key), mark)
    d: dict = {}
    for p in members:
        k, v = p.key, p.val
        if k in d:
            raise NotHeld(f"a dict repeats the key {k}")
        d[k] = v
    return Dict._trusted({k: d[k] for k in sorted(d, key=_ce_key)}, mark)


class _Pair:
    __slots__ = ("key", "val")

    def __init__(self, members: list):
        self.key, self.val = members


def _children(v: Value) -> list:
    if v.kind == Kind.DICT:
        return list(v.items())
    return list(v)


def to_carrier(v: Value) -> Any:
    """``v`` as a carrier tree of ``dict``/``list``/``str``/``int``/``bool``,
    ready for ``json.dumps`` (whose int-to-str limit applies to integers
    past 4300 digits; :func:`to_json` has none)."""
    def node(x: Value) -> dict:
        n: dict = {"kind": KIND_NAMES[x.kind]}
        if x.mark:
            n["mark"] = True
        k = x.kind
        if k == Kind.INTEGER or k == Kind.TEXT or k == Kind.SYMBOL:
            n["value"] = x.value
        elif k == Kind.BYTES:
            n["value"] = "0x" + x.value.hex()
        elif k >= 6:
            n["value"] = []
        return n

    root = node(v)
    stack = [(v, root["value"])] if v.kind >= 6 else []
    while stack:
        x, out = stack.pop()
        for c in _children(x):
            if x.kind == Kind.DICT:
                pair = [node(c[0]), node(c[1])]
                out.append(pair)
                for m, n in zip(c, pair):
                    if m.kind >= 6:
                        stack.append((m, n["value"]))
            else:
                n = node(c)
                out.append(n)
                if c.kind >= 6:
                    stack.append((c, n["value"]))
    return root


def _atom_json(x: Value) -> str:
    k = x.kind
    if k == Kind.INTEGER:
        return ', "value": ' + x.spelling
    if k == Kind.TEXT or k == Kind.SYMBOL:
        return ', "value": ' + json.dumps(x.value, ensure_ascii=False)
    if k == Kind.BYTES:
        return ', "value": "0x' + x.value.hex() + '"'
    return ""


def to_json(v: Value, *, indent: int | None = None) -> str:
    """``v`` as carrier JSON text, compact or indented by ``indent``
    spaces. Integers of any width are written exactly."""
    def nl(depth: int) -> str:
        return "" if indent is None else "\n" + " " * (indent * depth)

    comma = ", " if indent is None else ","
    out: list[str] = []
    # work items: a str to write, or (value, depth)
    work: list = [(v, 0)]
    while work:
        item = work.pop()
        if item.__class__ is str:
            out.append(item)
            continue
        x, d = item
        head = '{"kind": "' + KIND_NAMES[x.kind] + '"'
        if x.mark:
            head += ', "mark": true'
        if x.kind < 6:
            out.append(head + _atom_json(x) + "}")
            continue
        children = _children(x)
        if not children:
            out.append(head + ', "value": []}')
            continue
        out.append(head + ', "value": [')
        work.append(nl(d) + "]}")
        for i in range(len(children) - 1, -1, -1):
            c = children[i]
            if x.kind == Kind.DICT:
                work.append(nl(d + 1) + "]")
                work.append((c[1], d + 2))
                work.append(comma + nl(d + 2))
                work.append((c[0], d + 2))
                work.append(nl(d + 1) + "[" + nl(d + 2))
            else:
                work.append((c, d + 1))
                work.append(nl(d + 1))
            if i:
                work.append(comma.rstrip() if indent is not None else comma)
    return "".join(out)
