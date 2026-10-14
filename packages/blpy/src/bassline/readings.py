"""Readings between host values and values.

A reading in turns Python objects into values; a reading out turns values
into Python objects. Each is a small object holding its own rules, and none
is a registry everything must pass through: :data:`to_value` is a
convenient default, its siblings sit beside it, and ``.but(...)`` makes a
new sibling from any of them.

Both directions refuse what they cannot hold (:class:`NotHeld`) and never
coerce: a ``bool`` or ``float`` never becomes a value, and a symbol never
quietly becomes a ``str`` unless the reading says so by name.

A host type can declare its own default reading in by defining
``__bassline__(self) -> Value``; a reading's own rule for that type, if it
has one, comes first.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from collections.abc import Set as AbcSet
from typing import Any

from . import values as _values
from .errors import NotHeld
from .values import Bytes, Dict, Integer, List, Nil, Set, Symbol, Text, Value

__all__ = [
    "Reading",
    "ReadingOut",
    "to_value",
    "symbolic",
    "symbol_keys",
    "to_python",
    "plain",
]

RuleIn = Callable[[Any, Callable[[Any], Value]], Value]
RuleOut = Callable[..., Any]


# ---------------------------------------------------------------- in


class _ReadIn:
    """One conversion: the rules, plus the containers on the current path,
    so a cycle is refused instead of recursing forever."""

    __slots__ = ("rules", "path")

    def __init__(self, rules: dict):
        self.rules = rules
        self.path: set[int] = set()

    def __call__(self, x: Any) -> Value:
        if isinstance(x, Value):
            return x
        rule = self._rule_for(type(x))
        if rule is None:
            raise NotHeld(f"no reading of {type(x).__name__} as a value")
        key = id(x)
        if key in self.path:
            raise NotHeld("a cycle cannot be a value: values are trees")
        self.path.add(key)
        try:
            v = rule(x, self)
        finally:
            self.path.discard(key)
        if not isinstance(v, Value):
            raise TypeError(f"the reading of {type(x).__name__} gave "
                            f"{type(v).__name__}, not a value")
        return v

    def _rule_for(self, t: type):
        rules = self.rules
        for c in t.__mro__:
            rule = rules.get(c)
            if rule is not None:
                return rule
            if "__bassline__" in c.__dict__:
                return _hook
        if issubclass(t, Mapping):
            return rules.get(Mapping)
        if issubclass(t, AbcSet):
            return rules.get(AbcSet)
        if issubclass(t, Sequence) and not issubclass(t, (str, bytes, bytearray)):
            return rules.get(Sequence)
        return None


def _hook(x: Any, read) -> Value:
    return x.__bassline__()


class Reading:
    """A reading in: host objects to values, by rules keyed on host types.

    A rule is ``rule(obj, read) -> Value``, where ``read`` reads members
    with this same reading. Rules are found along the object's MRO, so a
    rule for ``dict`` covers its subclasses; ``Mapping``, ``Set`` and
    ``Sequence`` rules catch other collections.
    """

    __slots__ = ("name", "_rules")

    def __init__(self, rules: Mapping[type, RuleIn], name: str = "reading"):
        self.name = name
        self._rules = dict(rules)

    def __call__(self, x: Any) -> Value:
        return _ReadIn(self._rules)(x)

    def but(self, rules: Mapping[type, RuleIn], name: str | None = None) -> Reading:
        """A sibling reading: this one, with ``rules`` in place of its own
        for those types."""
        merged = dict(self._rules)
        merged.update(rules)
        return Reading(merged, name or f"{self.name}+")

    def __repr__(self) -> str:
        return f"<reading {self.name}>"


def _refuse_bool(x, read):
    raise NotHeld("a bool is not a value: booleans are vocabulary, such as a "
                  "symbol, or presence in a set")


def _refuse_float(x, read):
    raise NotHeld("a float is not a value: a non-integer number is "
                  "vocabulary, such as (dec 15 -1)")


def _list_in(x, read) -> Value:
    return List._trusted(tuple(read(m) for m in x))


def _dict_in(x, read) -> Value:
    return Dict(((read(k), read(v)) for k, v in x.items()))


def _set_in(x, read) -> Value:
    members = [read(m) for m in x]
    s = Set(members)
    if len(s) != len(members):
        raise NotHeld("distinct host members read as one value; a set "
                      "can't hold them apart")
    return s


_DEFAULT_IN: dict[type, RuleIn] = {
    type(None): lambda x, read: Nil(),
    bool: _refuse_bool,
    int: lambda x, read: Integer(x),
    float: _refuse_float,
    complex: _refuse_float,
    str: lambda x, read: Text(x),
    bytes: lambda x, read: Bytes(x),
    bytearray: lambda x, read: Bytes(x),
    memoryview: lambda x, read: Bytes(x),
    list: _list_in,
    tuple: _list_in,
    dict: _dict_in,
    set: _set_in,
    frozenset: _set_in,
    Mapping: _dict_in,
    AbcSet: _set_in,
    Sequence: _list_in,
}

#: The default reading in: ``None`` is nil, ``int`` an integer, ``str``
#: text, ``bytes`` bytes, ``list``/``tuple`` a list, ``dict`` a dict,
#: ``set``/``frozenset`` a set. ``bool`` and ``float`` are refused.
to_value = Reading(_DEFAULT_IN, "to_value")

#: Every ``str`` read as a symbol.
symbolic = to_value.but({str: lambda x, read: Symbol(x)}, "symbolic")


def _symbol_keys_dict(x, read) -> Value:
    return Dict(((Symbol(k) if isinstance(k, str) else read(k), read(v))
                 for k, v in x.items()))


#: ``str`` dict keys read as symbols, every other ``str`` as text:
#: ``{"name": "Ada"}`` is ``{name: "Ada"}``.
symbol_keys = to_value.but({dict: _symbol_keys_dict, Mapping: _symbol_keys_dict},
                           "symbol_keys")

_values._reading_in = to_value


# ---------------------------------------------------------------- out


class _ReadOut:
    __slots__ = ("rules",)

    def __init__(self, rules: dict):
        self.rules = rules

    def __call__(self, v: Value, *, hashable: bool = False) -> Any:
        if not isinstance(v, Value):
            raise TypeError(f"a reading out reads values, not {type(v).__name__}")
        rule = self.rules.get(type(v))
        if rule is None:
            raise NotHeld(f"this reading has no host form for {v.kind.name.lower()} "
                          f"values: {v}")
        return rule(v, self, hashable)


class ReadingOut:
    """A reading out: values to host objects, by rules keyed on the value
    classes. A rule is ``rule(value, read, hashable) -> object``, where
    ``read(member, hashable=...)`` reads members with this same reading and
    ``hashable`` says the result will be a dict key or set member."""

    __slots__ = ("name", "_rules")

    def __init__(self, rules: Mapping[type, RuleOut], name: str = "reading out"):
        self.name = name
        self._rules = dict(rules)

    def __call__(self, v: Value) -> Any:
        return _ReadOut(self._rules)(v)

    def but(self, rules: Mapping[type, RuleOut], name: str | None = None) -> ReadingOut:
        """A sibling: this reading with ``rules`` in place of its own."""
        merged = dict(self._rules)
        merged.update(rules)
        return ReadingOut(merged, name or f"{self.name}+")

    def __repr__(self) -> str:
        return f"<reading out {self.name}>"


def _unmarked(rule: RuleOut) -> RuleOut:
    def checked(v, read, hashable):
        if v.mark:
            raise NotHeld(f"a Python object has no mark to hold: {v}")
        return rule(v, read, hashable)
    return checked


def _list_out(v, read, hashable):
    items = [read(m, hashable=hashable) for m in v]
    return tuple(items) if hashable else items


def _dict_out(v, read, hashable):
    if hashable:
        raise NotHeld(f"a dict can't be a Python dict key or set member: {v}")
    out = {read(k, hashable=True): read(x) for k, x in v.items()}
    if len(out) != len(v):
        raise NotHeld(f"distinct keys read as one Python key; a dict would lose an entry: {v}")
    return out


def _set_out(v, read, hashable):
    out = frozenset(read(m, hashable=True) for m in v)
    if len(out) != len(v):
        raise NotHeld(f"distinct members read as one Python object; a set would lose one: {v}")
    return out


_DEFAULT_OUT: dict[type, RuleOut] = {
    Nil: _unmarked(lambda v, read, h: None),
    Integer: _unmarked(lambda v, read, h: v.value),
    Text: _unmarked(lambda v, read, h: v.value),
    Bytes: _unmarked(lambda v, read, h: v.value),
    List: _unmarked(_list_out),
    Dict: _unmarked(_dict_out),
    Set: _unmarked(_set_out),
}

#: The default reading out: nil is ``None``, integers ``int``, text
#: ``str``, bytes ``bytes``, lists ``list`` (``tuple`` inside a key or set
#: member), dicts ``dict``, sets ``frozenset``. Symbols, records and marked
#: values have no Python form that keeps what they are, so they are refused.
to_python = ReadingOut(_DEFAULT_OUT, "to_python")

#: :data:`to_python`, but symbols read as ``str``, giving up the
#: difference from text. Records and marks are still refused, and so is a
#: dict or set where a symbol and a text would collapse into one entry.
plain = to_python.but({Symbol: _unmarked(lambda v, read, h: v.value)}, "plain")
