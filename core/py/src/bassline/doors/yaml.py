"""YAML, through PyYAML when it is installed (the door is absent otherwise).

The first pass reads PyYAML's node graph rather than its Python objects,
so nothing goes through a float or a guess of its own:

- mappings are dicts (keys may be any value), sequences lists, strings
  text, nulls nil, ``true`` and ``false`` the symbols, integers integers of
  any size (``-0`` has no integer form and is ``(number "-0")``);
- a float is read from its spelling: ``1.50`` is ``(dec 150 -2)``; what has
  no ``dec`` form (``.inf``, ``.nan``, ``-0.0``) is kept as
  ``(number "…")``;
- a plain scalar that YAML 1.1 and YAML 1.2 read differently is kept as the
  text written: ``no``, ``on``, ``010``, ``1:30``, ``1_000``, ``1e3``,
  ``2002-12-14``. PyYAML reads YAML 1.1, where ``no`` is false and ``010``
  is 8; YAML 1.2 reads them as text and 10. A lever can reread them;
- an explicit tag is taken at its word, with the door's own checks:
  ``!!timestamp 2001-12-14t21:59:43.10-05:00`` is ``(datetime (date 2001 12
  14) (time 21 59 (dec 4310 -2)) (offset -300))``, every digit kept;
  ``!!binary`` is bytes, ``!!set`` a set, ``!!float 1`` is ``(dec 1 0)``; a
  spelling that doesn't fit its tag is refused;
- any other tag becomes a record head: ``!point [1, 2]`` is ``(point 1 2)``,
  ``!label red`` is ``(label "red")``, and a tag in YAML's own namespace
  keeps it: ``!!omap`` is the head ``'!!omap'``;
- anchors and aliases are expanded (the result is a tree), and an alias
  that contains itself is refused; a merge key ``<<`` is kept as the key it
  is, not merged;
- a key given twice in one mapping is refused, as JSON's dict reading
  refuses it;
- each document in a stream is one value.

The writer writes each value as one document: dicts, lists and sets in
block style, ``dec`` and ``(number …)`` as floats, date records as
timestamps, bytes as ``!!binary``, and other records as sequences tagged
with their head (``(point 1 2)`` is ``!point [1, 2]``), which this door
reads back as the same record. Text that either YAML version would read as
something else is quoted, and a value either would misread is tagged.
"""

from __future__ import annotations

import base64
import binascii
import re
from collections.abc import Iterator
from typing import Any

from ..errors import BasslineError, NotHeld
from ..values import Bytes, Dict, Integer, Kind, List, Set, Text, Value, _parse, nil, rec, sym
from . import _vocab
from ._door import Door, TextWriter, text_of, utf8_or_none

try:
    import yaml as _yaml
except ImportError:   # pragma: no cover - depends on the host
    _yaml = None

__all__ = ["door", "read", "loads", "dumps", "writer", "sure"]

_STD = "tag:yaml.org,2002:"
_TAG_NAME = re.compile(r"[A-Za-z0-9_.-]+\Z")
_CANONICAL_INT = re.compile(r"[-+]?(0|[1-9][0-9]*)\Z")
_LEADING_ZERO = re.compile(r"[-+]?0[0-9]+\Z")
_SPECIAL_FLOAT = re.compile(r"[-+]?\.(inf|Inf|INF)\Z|\.(nan|NaN|NAN)\Z"
                            r"|[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+\.[0-9_]*\Z")
_TIMESTAMP = re.compile(
    r"(?P<y>[0-9]{4})-(?P<mo>[0-9]{1,2})-(?P<d>[0-9]{1,2})"
    r"(?:(?:[Tt]|[ \t]+)(?P<h>[0-9]{1,2}):(?P<mi>[0-9]{2}):(?P<s>[0-9]{2})"
    r"(?:\.(?P<f>[0-9]*))?"
    r"(?:[ \t]*(?P<tz>Z|(?P<sign>[-+])(?P<th>[0-9]{1,2})(?::(?P<tm>[0-9]{2}))?))?)?\Z")

#: YAML 1.2's core schema, for plain scalars.
_CORE = (
    ("null", re.compile(r"(~|null|Null|NULL|)\Z")),
    ("bool", re.compile(r"(true|True|TRUE|false|False|FALSE)\Z")),
    ("int", re.compile(r"[-+]?[0-9]+\Z|0o[0-7]+\Z|0x[0-9a-fA-F]+\Z")),
    ("float", re.compile(r"[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?\Z"
                         r"|[-+]?\.(inf|Inf|INF)\Z|\.(nan|NaN|NAN)\Z")),
)
_AMBIGUOUS = "tag:bassline,2026:ambiguous"


def _core_tag(value: str) -> str:
    for tag, rx in _CORE:
        if rx.match(value):
            if tag == "int" and _LEADING_ZERO.match(value):
                break       # octal in YAML 1.1, decimal in 1.2
            return _STD + tag
    return _STD + "str"


if _yaml is not None:
    class _Loader(_yaml.SafeLoader):
        """PyYAML's safe loader, but a plain scalar that YAML 1.1 and 1.2
        read differently resolves to text."""

        def resolve(self, kind, value, implicit):
            tag = super().resolve(kind, value, implicit)
            if kind is _yaml.ScalarNode and implicit[0] and tag != _core_tag(value):
                return _STD + "str"
            return tag

    class _Dumper(_yaml.SafeDumper):
        """PyYAML's safe dumper, writing plain only what both YAML versions
        read alike: other text is quoted, other values tagged."""

        def resolve(self, kind, value, implicit):
            tag = super().resolve(kind, value, implicit)
            if kind is _yaml.ScalarNode and implicit[0] and tag != _core_tag(value):
                return _AMBIGUOUS
            return tag


def _head(tag: str) -> Value:
    if tag.startswith(_STD):
        return sym("!!" + tag[len(_STD):])
    if tag.startswith("!"):
        return sym(tag[1:])
    return sym(tag)


def _timestamp(s: str) -> Value:
    m = _TIMESTAMP.match(s)
    if m is None:
        raise NotHeld(f"!!timestamp {s!r} isn't a timestamp")
    g = m.groupdict()
    date = _vocab.date_record(int(g["y"]), int(g["mo"]), int(g["d"]))
    if g["h"] is None:
        return date
    offset = None
    if g["tz"] == "Z":
        offset = 0
    elif g["tz"]:
        minutes = int(g["th"]) * 60 + int(g["tm"] or 0)
        offset = -minutes if g["sign"] == "-" else minutes
    time = _vocab.time_record(int(g["h"]), int(g["mi"]), g["s"], g["f"] or "")
    return _vocab.datetime_record(date, time, offset)


def _float(s: str) -> Value:
    v = _vocab.number(s.replace("_", ""), lenient=True)
    if v is None:
        if not _SPECIAL_FLOAT.match(s):
            raise NotHeld(f"!!float {s!r} isn't a float")
        return rec(_vocab.NUMBER, Text(s))
    if v.kind == Kind.INTEGER:
        return _vocab.dec(v.value, 0)
    return v


class _Reader:
    def __init__(self, loader):
        self.loader = loader
        self.path: set[int] = set()

    def node(self, n) -> Value:
        key = id(n)
        if key in self.path:
            raise NotHeld("an alias that contains itself can't be a value: values are trees")
        self.path.add(key)
        try:
            if isinstance(n, _yaml.ScalarNode):
                return self.scalar(n)
            if isinstance(n, _yaml.SequenceNode):
                items = [self.node(c) for c in n.value]
                if n.tag == _STD + "seq":
                    return List._trusted(tuple(items))
                return rec(_head(n.tag), *items)
            return self.mapping(n)
        finally:
            self.path.discard(key)

    def scalar(self, n) -> Value:
        tag, s = n.tag, n.value
        try:
            if tag == _STD + "str":
                return Text(s)
            if tag == _STD + "null":
                if s not in ("~", "null", "Null", "NULL", ""):
                    raise NotHeld(f"!!null {s!r} isn't a null")
                return nil
            if tag == _STD + "bool":
                return _vocab.TRUE if self.loader.construct_yaml_bool(n) else _vocab.FALSE
            if tag == _STD + "int":
                if _CANONICAL_INT.match(s):
                    v = _vocab.number(s.lstrip("+"))
                    return v
                return Integer(self.loader.construct_yaml_int(n))
            if tag == _STD + "float":
                return _float(s)
            if tag == _STD + "timestamp":
                return _timestamp(s)
            if tag == _STD + "binary":
                return Bytes(base64.b64decode("".join(s.split()), validate=True))
            if tag in (_STD + "merge", _STD + "value"):
                return Text(s)
            return rec(_head(tag), Text(s))
        except BasslineError:
            raise
        except (ValueError, KeyError, AttributeError, TypeError, OverflowError,
                binascii.Error, _yaml.YAMLError):
            raise NotHeld(f"{_head(tag)} {s!r} doesn't spell what its tag says") from None

    def mapping(self, n) -> Value:
        pairs: dict[Value, Value] = {}
        for kn, vn in n.value:
            k = self.node(kn)
            if k in pairs:
                raise NotHeld(f"the key {k} appears twice in one mapping; a dict "
                              "holds each key once")
            pairs[k] = self.node(vn)
        if n.tag == _STD + "set":
            if any(v != nil for v in pairs.values()):
                raise NotHeld("a !!set's members have no values, and this one has")
            return Set(pairs)
        d = Dict(pairs)
        return d if n.tag == _STD + "map" else rec(_head(n.tag), d)


def _nodes(text: str) -> Iterator[Any]:
    loader = _Loader(text)
    try:
        while loader.check_node():
            yield loader, loader.get_node()
    except _yaml.YAMLError as e:
        raise NotHeld(f"not YAML: {' '.join(str(e).split())}") from None
    finally:
        loader.dispose()


# ---------------------------------------------------------------- writing


def _scalar(tag: str, value: str, style: str | None = None):
    return _yaml.ScalarNode(_STD + tag, value, style=style)


def _to_node(v: Value):
    k = v.kind
    if k == Kind.NIL:
        return _scalar("null", "null")
    if k == Kind.INTEGER:
        return _scalar("int", v.spelling)
    if k == Kind.TEXT:
        return _scalar("str", v.value)
    if k == Kind.SYMBOL:
        if v.name in ("true", "false"):
            return _scalar("bool", v.name)
        return _scalar("str", v.name)
    if k == Kind.BYTES:
        return _scalar("binary", base64.encodebytes(v.value).decode("ascii"), "|")
    if k == Kind.LIST:
        return _yaml.SequenceNode(_STD + "seq", [_to_node(m) for m in v], flow_style=False)
    if k == Kind.SET:
        return _yaml.MappingNode(_STD + "set", [(n, _scalar("null", "")) for n, _ in
                                                _keyed((m, None) for m in v)], flow_style=False)
    if k == Kind.DICT:
        return _yaml.MappingNode(_STD + "map", [(n, _to_node(b)) for n, b in
                                                _keyed(v.items())], flow_style=False)
    s = _vocab.spelling(v)
    if s is not None:
        return _scalar("float", s)
    s = _vocab.iso(v)
    if s is not None:
        return _scalar("str" if v.head == _vocab.TIME else "timestamp", s)
    head = v.head
    if head.kind == Kind.SYMBOL and _TAG_NAME.match(head.name.removeprefix("!!")):
        tag = (_STD + head.name[2:]) if head.name.startswith("!!") else "!" + head.name
        return _yaml.SequenceNode(tag, [_to_node(m) for m in v.fields], flow_style=True)
    return _yaml.SequenceNode(_STD + "seq", [_to_node(m) for m in v], flow_style=False)


def _keyed(entries) -> list:
    """Mapping keys as nodes, refusing two that YAML would read as one
    (the text "a" and the symbol a are both the string a)."""
    seen: dict = {}
    out = []
    for k, x in entries:
        n = _to_node(k)
        if isinstance(n, _yaml.ScalarNode):
            spelled = (n.tag, n.value)
            if spelled in seen:
                raise NotHeld(f"the keys {seen[spelled]} and {k} would both be "
                              f"{n.value!r} in YAML, which can't hold both")
            seen[spelled] = k
        out.append((n, x))
    return out


def to_yaml(v: Value) -> str:
    """One value as a YAML document."""
    return _yaml.serialize(_to_node(v), Dumper=_Dumper, allow_unicode=True,
                           explicit_start=True)


class YAMLDoor(Door):
    name = "yaml"
    summary = "YAML: tags as record heads, anchors expanded (needs PyYAML)"
    extensions = (".yaml", ".yml")
    readings = ("yaml",)
    writers = ("yaml",)
    needs = "" if _yaml is not None else "PyYAML"

    def sure(self, data: bytes | str) -> int:
        if self.needs:
            return 0
        text = utf8_or_none(data)
        if not text or not text.strip():
            return 0
        try:
            nodes = [n for _, n in _nodes(text)]
        except NotHeld:
            return 0
        if not nodes:
            return 0
        n = nodes[0]
        if isinstance(n, _yaml.ScalarNode):
            return 10
        return 30 if n.flow_style else 45

    def _read(self, data, reading) -> Iterator[Value]:
        text = text_of(data, "YAML")
        return (_Reader(loader).node(n) for loader, n in _nodes(text))

    def _writer(self, out: Any, name: str) -> TextWriter:
        return TextWriter(out, to_yaml)


door = YAMLDoor()
read = door.read
loads = door.loads
dumps = door.dumps
writer = door.writer
sure = door.sure
