"""Values: nine kinds and a mark, immutable, identified by their bytes.

A value is an atom (:class:`Nil`, :class:`Integer`, :class:`Text`,
:class:`Symbol`, :class:`Bytes`) or a frame (:class:`List`, :class:`Record`,
:class:`Dict`, :class:`Set`), and any value may carry the mark. Two values
are equal exactly when their canonical encodings (CE) are equal, and they
hash and sort by those bytes, so ``sorted()`` gives canonical order and
values work as ``dict`` keys. Frames behave like Python collections: a list
and a record are sequences, a dict is a mapping, a set is a set.

Nothing here subclasses ``int`` or ``str``: in Python ``1 == True == 1.0``,
and values must not inherit that. A value never equals a host object, so
``Integer(1) == 1`` is false; compare values with values.
"""

from __future__ import annotations

import enum
import re
import sys
from collections.abc import Iterable, Mapping, Sequence
from collections.abc import Set as AbcSet
from itertools import chain
from operator import attrgetter
from typing import Any

from .errors import NotHeld

__all__ = [
    "Kind",
    "Value",
    "Nil",
    "Integer",
    "Text",
    "Symbol",
    "Bytes",
    "List",
    "Record",
    "Dict",
    "Set",
    "nil",
    "sym",
    "rec",
    "mark",
    "unmark",
]

# ---------------------------------------------------------------- the wire

END = 0xA0
MARK_BIT = 0x08
MAX_PAYLOAD = 0xFFFF_FFFF
_END_BYTES = b"\xa0"


class Kind(enum.IntEnum):
    """The nine kinds. Each number is the kind's tag in the header byte."""

    NIL = 1
    INTEGER = 2
    TEXT = 3
    SYMBOL = 4
    BYTES = 5
    LIST = 6
    RECORD = 7
    DICT = 8
    SET = 9

    @property
    def is_frame(self) -> bool:
        return self >= 6


def _header(tag: int, mark: bool) -> int:
    return (tag << 4) | (MARK_BIT if mark else 0)


def _scalar_ce(tag: int, mark: bool, payload: bytes) -> bytes:
    """Header, length in the smallest form that fits, payload."""
    h = _header(tag, mark)
    n = len(payload)
    if n < 7:
        return bytes((h | n,)) + payload
    if n < 255:
        return bytes((h | 7, n)) + payload
    return bytes((h | 7, 255)) + n.to_bytes(4, "big") + payload


def _payload_of(ce: bytes) -> bytes:
    """A scalar's payload, past its header and length."""
    lb = ce[0] & 7
    if lb < 7:
        return ce[1:]
    return ce[2:] if ce[1] != 255 else ce[6:]


def _check_payload(n: int, what: str) -> None:
    if n > MAX_PAYLOAD:
        raise NotHeld(f"{what} payload of {n} bytes is past the encoding's "
                      f"4-byte length ({MAX_PAYLOAD})")


# ------------------------------------------------------------ integers

_CANONICAL = re.compile(rb"0|-?[1-9][0-9]*")


def is_canonical_spelling(spelling: bytes) -> bool:
    """Whether ``spelling`` is an integer's one spelling: ``0``, or an
    optional ``-`` and ASCII digits with no leading zero."""
    return _CANONICAL.fullmatch(spelling) is not None


def _spell(n: int) -> str:
    """Decimal spelling of any int, past ``sys.get_int_max_str_digits``."""
    try:
        return str(n)
    except ValueError:
        pass
    if n < 0:
        return "-" + _spell(-n)
    k = (int(n.bit_length() * 0.30102999566398) + 1) // 2
    hi, lo = divmod(n, 10 ** k)
    return _spell(hi) + _spell(lo).rjust(k, "0")


def _parse(spelling: str) -> int:
    """The int a canonical spelling names, past the str-digits limit."""
    try:
        return int(spelling)
    except ValueError:
        pass
    if spelling.startswith("-"):
        return -_parse(spelling[1:])
    k = len(spelling) // 2
    hi, lo = spelling[:-k], spelling[-k:]
    return _parse(hi) * 10 ** k + _parse(lo.lstrip("0") or "0")


# ------------------------------------------------------------ values

_set = object.__setattr__
_ce_key = attrgetter("ce")

#: Set by :mod:`bassline.readings` at import: the default reading in,
#: through which constructors read host members.
_reading_in: Any = None


def _read(x: Any) -> Value:
    if isinstance(x, Value):
        return x
    return _reading_in(x)


def _init(self: Value, mark: bool, ce: bytes | None = None) -> None:
    _set(self, "_mark", mark)
    _set(self, "_ce", ce)
    _set(self, "_hash", None)


class Value:
    """Base of the nine kinds. Immutable; equality, hashing and order come
    from the canonical encoding, which is computed once and cached."""

    __slots__ = ("_mark", "_ce", "_hash")
    kind: Kind
    _payload: tuple[str, ...] = ()

    def __init__(self, *args, **kwargs):
        raise TypeError("Value is abstract: build one of its nine kinds, "
                        "or read a host value with to_value()")

    # -- immutability
    def __setattr__(self, name, value):
        raise AttributeError(f"{type(self).__name__} values are immutable")

    def __delattr__(self, name):
        raise AttributeError(f"{type(self).__name__} values are immutable")

    def __copy__(self):
        return self

    def __deepcopy__(self, memo):
        return self

    def __reduce__(self):
        # a value travels as its bytes
        return (_from_ce, (self.ce,))

    # -- the mark
    @property
    def mark(self) -> bool:
        """Whether this value carries the mark ("something to do")."""
        return self._mark

    def with_mark(self, flag: bool = True) -> Value:
        """This value with the mark set to ``flag``; the payload is shared."""
        flag = bool(flag)
        if flag == self._mark:
            return self
        new = object.__new__(type(self))
        for slot in type(self)._payload:
            _set(new, slot, getattr(self, slot))
        ce = self._ce
        _init(new, flag, None if ce is None else bytes((ce[0] ^ MARK_BIT,)) + ce[1:])
        return new

    def marked(self) -> Value:
        """This value with the mark set."""
        return self.with_mark(True)

    def unmarked(self) -> Value:
        """This value without the mark."""
        return self.with_mark(False)

    # -- identity
    @property
    def ce(self) -> bytes:
        """The canonical encoding: this value's identity."""
        ce = self._ce
        if ce is None:
            ce = _compute_ce(self)
        return ce

    def __eq__(self, other):
        if other is self:
            return True
        if not isinstance(other, Value):
            return NotImplemented
        return self.ce == other.ce

    def __ne__(self, other):
        if other is self:
            return False
        if not isinstance(other, Value):
            return NotImplemented
        return self.ce != other.ce

    def __hash__(self):
        h = self._hash
        if h is None:
            h = hash(self.ce)
            _set(self, "_hash", h)
        return h

    def __lt__(self, other):
        if not isinstance(other, Value):
            return NotImplemented
        return self.ce < other.ce

    def __le__(self, other):
        if not isinstance(other, Value):
            return NotImplemented
        return self.ce <= other.ce

    def __gt__(self, other):
        if not isinstance(other, Value):
            return NotImplemented
        return self.ce > other.ce

    def __ge__(self, other):
        if not isinstance(other, Value):
            return NotImplemented
        return self.ce >= other.ce

    # -- printing
    def __str__(self) -> str:
        from .text import to_text
        return to_text(self)

    def __repr__(self) -> str:
        return f"bl({str(self)!r})"

    @property
    def is_frame(self) -> bool:
        return self.kind >= 6

    @property
    def is_atom(self) -> bool:
        return self.kind < 6

    def _atom_ce(self) -> bytes:  # pragma: no cover - frames never call it
        raise NotImplementedError

    def _constituents(self) -> Iterable[Value]:
        return ()


def _from_ce(ce: bytes) -> Value:
    # these bytes came from a value, so no limit of a boundary applies
    from .codec import decode
    return decode(ce, max_depth=sys.maxsize)


def _compute_ce(root: Value) -> bytes:
    """Encode ``root`` and every uncached value inside it, bottom up, with
    an explicit stack so depth never reaches the call stack."""
    stack = [root]
    while stack:
        v = stack[-1]
        if v._ce is not None:
            stack.pop()
            continue
        k = v.kind
        if k < 6:
            _set(v, "_ce", v._atom_ce())
            stack.pop()
            continue
        members = v._constituents()
        pending = [m for m in members if m._ce is None]
        if pending:
            stack.extend(pending)
            continue
        parts = [bytes((_header(k, v._mark),))]
        parts.extend(m._ce for m in v._constituents())
        parts.append(_END_BYTES)
        _set(v, "_ce", b"".join(parts))
        stack.pop()
    return root._ce


# ---------------------------------------------------------------- atoms


class Nil(Value):
    """A stated absence. Not a default, and not silence: a missing key is
    not nil."""

    __slots__ = ()
    kind = Kind.NIL
    __match_args__ = ()

    def __init__(self, *, mark: bool = False):
        _init(self, bool(mark))

    @property
    def value(self) -> None:
        return None

    def _atom_ce(self) -> bytes:
        return bytes((_header(1, self._mark),))


class Integer(Value):
    """An integer of any size. ``value`` is the Python ``int``."""

    __slots__ = ("_n",)
    kind = Kind.INTEGER
    __match_args__ = ("value",)
    _payload = ("_n",)

    def __init__(self, n: int, *, mark: bool = False):
        if isinstance(n, bool) or not isinstance(n, int):
            raise NotHeld(f"Integer takes an int, not {type(n).__name__}"
                          + (": booleans are vocabulary, not values"
                             if isinstance(n, bool) else ""))
        _set(self, "_n", int(n))
        _init(self, bool(mark))

    @classmethod
    def parse(cls, spelling: str, *, mark: bool = False) -> Integer:
        """The integer a canonical spelling names; refuses any other
        spelling (``"007"``, ``"-0"``, ``"+5"``, ``" 5"``)."""
        if not isinstance(spelling, str):
            raise NotHeld(f"Integer.parse takes a str, not {type(spelling).__name__}")
        raw = spelling.encode("ascii", "replace")
        if not is_canonical_spelling(raw):
            raise NotHeld(f"not a canonical integer spelling: {spelling!r}")
        _check_payload(len(raw), "integer")
        return cls._from_ce(_scalar_ce(2, bool(mark), raw))

    @classmethod
    def _from_ce(cls, ce: bytes) -> Integer:
        self = object.__new__(cls)
        _set(self, "_n", None)
        _init(self, bool(ce[0] & MARK_BIT), ce)
        return self

    @property
    def value(self) -> int:
        n = self._n
        if n is None:
            n = _parse(_payload_of(self._ce).decode("ascii"))
            _set(self, "_n", n)
        return n

    @property
    def spelling(self) -> str:
        """The canonical decimal spelling."""
        if self._ce is not None:
            return _payload_of(self._ce).decode("ascii")
        return _spell(self._n)

    def __int__(self) -> int:
        return self.value

    def __index__(self) -> int:
        return self.value

    def _atom_ce(self) -> bytes:
        payload = _spell(self._n).encode("ascii")
        _check_payload(len(payload), "integer")
        return _scalar_ce(2, self._mark, payload)


def _text_init(self: Value, s: Any, mark: bool, what: str) -> None:
    if not isinstance(s, str):
        raise NotHeld(f"{what} takes a str, not {type(s).__name__}")
    s = str.__str__(s)
    try:
        payload = s.encode("utf-8")
    except UnicodeEncodeError as e:
        raise NotHeld(f"{what} must be well-formed UTF-8: a lone surrogate "
                      f"at index {e.start} has no UTF-8 form") from None
    _check_payload(len(payload), what.lower())
    _set(self, "_s", s)
    _init(self, bool(mark), _scalar_ce(self.kind, bool(mark), payload))


class _Textual(Value):
    """What text and symbols share: a Python string with a UTF-8 form."""

    __slots__ = ("_s",)
    _payload = ("_s",)

    @classmethod
    def _trusted(cls, s: str, ce: bytes) -> Value:
        self = object.__new__(cls)
        _set(self, "_s", s)
        _init(self, bool(ce[0] & MARK_BIT), ce)
        return self

    @property
    def value(self) -> str:
        return self._s

    def _atom_ce(self) -> bytes:  # pragma: no cover - always cached
        return _scalar_ce(self.kind, self._mark, self._s.encode("utf-8"))


class Text(_Textual):
    """Text: a ``str`` that has a UTF-8 form, kept exactly (never
    normalised: NFC and NFD spellings are different values).
    ``str(Text("hi"))`` is the textual syntax, ``"hi"`` with quotes;
    ``.value`` is the Python string."""

    __slots__ = ()
    kind = Kind.TEXT
    __match_args__ = ("value",)

    def __init__(self, s: str, *, mark: bool = False):
        _text_init(self, s, mark, "Text")


class Symbol(_Textual):
    """A symbol: like text, but a name rather than a run of characters.
    ``.name`` and ``.value`` are the Python string. :data:`sym` builds
    them: ``sym.person`` or ``sym("has space")``."""

    __slots__ = ()
    kind = Kind.SYMBOL
    __match_args__ = ("name",)

    def __init__(self, name: str, *, mark: bool = False):
        _text_init(self, name, mark, "Symbol")

    @property
    def name(self) -> str:
        return self._s


class Bytes(Value):
    """Raw bytes. ``.value`` is the Python ``bytes``."""

    __slots__ = ("_b",)
    kind = Kind.BYTES
    __match_args__ = ("value",)
    _payload = ("_b",)

    def __init__(self, b: bytes | bytearray | memoryview, *, mark: bool = False):
        if not isinstance(b, (bytes, bytearray, memoryview)):
            raise NotHeld(f"Bytes takes bytes, not {type(b).__name__}")
        b = bytes(b)
        _check_payload(len(b), "bytes")
        _set(self, "_b", b)
        _init(self, bool(mark))

    @classmethod
    def _trusted(cls, b: bytes, ce: bytes) -> Value:
        self = object.__new__(cls)
        _set(self, "_b", b)
        _init(self, bool(ce[0] & MARK_BIT), ce)
        return self

    @property
    def value(self) -> bytes:
        return self._b

    def _atom_ce(self) -> bytes:
        return _scalar_ce(5, self._mark, self._b)


# ---------------------------------------------------------------- frames


def _refuse_scalar_iterable(members: Any, what: str) -> None:
    if isinstance(members, (str, bytes, bytearray, memoryview)) or (
            isinstance(members, Value) and members.kind < 6):
        raise NotHeld(f"{what} takes an iterable of members, not a single "
                      f"{type(members).__name__}")


class List(Value, Sequence):
    """Values by position. A Python sequence: index it, slice it (a slice
    is a new unmarked list), iterate it, ``+`` it."""

    __slots__ = ("_m",)
    kind = Kind.LIST
    __match_args__ = ("members",)
    _payload = ("_m",)

    def __init__(self, members: Iterable[Any] = (), *, mark: bool = False):
        _refuse_scalar_iterable(members, "List")
        _set(self, "_m", tuple(_read(x) for x in members))
        _init(self, bool(mark))

    @classmethod
    def _trusted(cls, members: tuple, mark: bool = False) -> List:
        self = object.__new__(cls)
        _set(self, "_m", members)
        _init(self, mark)
        return self

    @property
    def members(self) -> tuple[Value, ...]:
        return self._m

    def _constituents(self):
        return self._m

    def __len__(self) -> int:
        return len(self._m)

    def __iter__(self):
        return iter(self._m)

    def __reversed__(self):
        return reversed(self._m)

    def __getitem__(self, i):
        if isinstance(i, slice):
            return List._trusted(self._m[i])
        return self._m[i]

    def __contains__(self, x) -> bool:
        return _read(x) in self._m

    def __add__(self, other):
        if isinstance(other, (str, bytes)) or not isinstance(other, Iterable):
            return NotImplemented
        return List._trusted(self._m + tuple(_read(x) for x in other))

    def __radd__(self, other):
        if isinstance(other, (str, bytes)) or not isinstance(other, Iterable):
            return NotImplemented
        return List._trusted(tuple(_read(x) for x in other) + self._m)

    def map(self, fn) -> List:
        """A list of ``fn(member)`` for each member, with this list's mark."""
        return List._trusted(tuple(_read(fn(m)) for m in self._m), self._mark)


class Record(Value, Sequence):
    """A head value, then fields. ``Record(head, *fields)``; the head is
    required. As a sequence it is head first, like its encoding:
    ``r[0] is r.head``, and ``r.fields`` is the rest."""

    __slots__ = ("_m",)
    kind = Kind.RECORD
    __match_args__ = ("head", "fields")
    _payload = ("_m",)

    def __init__(self, head: Any, *fields: Any, mark: bool = False):
        _set(self, "_m", (_read(head),) + tuple(_read(x) for x in fields))
        _init(self, bool(mark))

    @classmethod
    def _trusted(cls, items: tuple, mark: bool = False) -> Record:
        self = object.__new__(cls)
        _set(self, "_m", items)
        _init(self, mark)
        return self

    @property
    def head(self) -> Value:
        return self._m[0]

    @property
    def fields(self) -> tuple[Value, ...]:
        return self._m[1:]

    def _constituents(self):
        return self._m

    def __len__(self) -> int:
        return len(self._m)

    def __iter__(self):
        return iter(self._m)

    def __reversed__(self):
        return reversed(self._m)

    def __getitem__(self, i):
        # a slice of a record need not keep its head, so it is a tuple
        return self._m[i]

    def __contains__(self, x) -> bool:
        return _read(x) in self._m

    def map(self, fn) -> Record:
        """A record of ``fn(item)`` for the head and each field, with this
        record's mark."""
        return Record._trusted(tuple(_read(fn(m)) for m in self._m), self._mark)


def _sorted_unique(pairs: Iterable[tuple[Value, Any]], what: str) -> dict:
    tmp: dict = {}
    for k, v in pairs:
        if k in tmp:
            raise NotHeld(f"{what} key given twice: {k}")
        tmp[k] = v
    return {k: tmp[k] for k in sorted(tmp, key=_ce_key)}


class Dict(Value, Mapping):
    """Associations from keys to values, any values, unique keys, kept in
    canonical order. A Python mapping: ``d[k]``, ``d.get(k)``, ``k in d``,
    ``d.items()``. A host key is read with the default reading, so
    ``d["name"]`` looks up the *text* ``"name"``; symbol keys are
    ``d[sym.name]``. A missing key is silence (``KeyError``, or ``get``'s
    default), never nil."""

    __slots__ = ("_d",)
    kind = Kind.DICT
    _payload = ("_d",)

    def __init__(self, entries: Mapping | Iterable[tuple[Any, Any]] = (), *,
                 mark: bool = False):
        pairs = entries.items() if isinstance(entries, Mapping) else entries
        _set(self, "_d", _sorted_unique(
            ((_read(k), _read(v)) for k, v in pairs), "Dict"))
        _init(self, bool(mark))

    @classmethod
    def _trusted(cls, d: dict, mark: bool = False) -> Dict:
        self = object.__new__(cls)
        _set(self, "_d", d)
        _init(self, mark)
        return self

    def _constituents(self):
        return tuple(chain.from_iterable(self._d.items()))

    def __len__(self) -> int:
        return len(self._d)

    def __iter__(self):
        return iter(self._d)

    def __getitem__(self, key):
        return self._d[_read(key)]

    def __contains__(self, key) -> bool:
        return _read(key) in self._d

    def get(self, key, default=None):
        return self._d.get(_read(key), default)

    def keys(self):
        return self._d.keys()

    def values(self):
        return self._d.values()

    def items(self):
        return self._d.items()

    def __or__(self, other):
        if not isinstance(other, Mapping):
            return NotImplemented
        merged = dict(self._d)
        for k, v in other.items():
            merged[_read(k)] = _read(v)
        return Dict._trusted({k: merged[k] for k in sorted(merged, key=_ce_key)})

    def __ror__(self, other):
        if not isinstance(other, Mapping):
            return NotImplemented
        return Dict(other) | self

    def without(self, *keys) -> Dict:
        """This dict without ``keys`` (unmarked, as a new value)."""
        drop = {_read(k) for k in keys}
        return Dict._trusted({k: v for k, v in self._d.items() if k not in drop})

    def map(self, fn) -> Dict:
        """A dict of ``key: fn(value)``, with this dict's mark."""
        return Dict._trusted({k: _read(fn(v)) for k, v in self._d.items()},
                             self._mark)


class Set(Value, AbcSet):
    """Unique members, kept in canonical order. A Python set: ``x in s``,
    iteration, ``| & - ^``. ``Set(iterable)`` drops repeats as ``set()``
    does (the reader and decoder refuse them instead). ``<`` is canonical
    order between values; subsets are :meth:`issubset`."""

    __slots__ = ("_d",)
    kind = Kind.SET
    __match_args__ = ("members",)
    _payload = ("_d",)

    def __init__(self, members: Iterable[Any] = (), *, mark: bool = False):
        _refuse_scalar_iterable(members, "Set")
        tmp = dict.fromkeys(_read(x) for x in members)
        _set(self, "_d", dict.fromkeys(sorted(tmp, key=_ce_key)))
        _init(self, bool(mark))

    @classmethod
    def _trusted(cls, members: Iterable[Value], mark: bool = False) -> Set:
        self = object.__new__(cls)
        _set(self, "_d", dict.fromkeys(members))
        _init(self, mark)
        return self

    @classmethod
    def _from_iterable(cls, it):
        return cls(it)

    @property
    def members(self) -> tuple[Value, ...]:
        return tuple(self._d)

    def _constituents(self):
        return tuple(self._d)

    def __len__(self) -> int:
        return len(self._d)

    def __iter__(self):
        return iter(self._d)

    def __contains__(self, x) -> bool:
        return _read(x) in self._d

    def issubset(self, other: Iterable) -> bool:
        other = other if isinstance(other, Set) else Set(other)
        return all(m in other._d for m in self._d)

    def issuperset(self, other: Iterable) -> bool:
        return all(_read(m) in self._d for m in other)

    def map(self, fn) -> Set:
        """A set of ``fn(member)`` for each member, with this set's mark;
        members that map to one value become one member."""
        return Set((fn(m) for m in self._d), mark=self._mark)


# ---------------------------------------------------------------- helpers


class _SymbolMaker:
    """``sym("has space")`` or ``sym.person``: a symbol, by name."""

    __slots__ = ()

    def __call__(self, name: str, *, mark: bool = False) -> Symbol:
        return Symbol(name, mark=mark)

    def __getattr__(self, name: str) -> Symbol:
        if name.startswith("__"):
            raise AttributeError(name)
        return Symbol(name)

    def __repr__(self) -> str:
        return "sym"


sym = _SymbolMaker()

#: The unmarked nil.
nil = Nil()


def rec(head: Any, *fields: Any, mark: bool = False) -> Record:
    """``rec(sym.point, 1, 2)`` is ``(point 1 2)``: a record."""
    return Record(head, *fields, mark=mark)


def mark(x: Any) -> Value:
    """``x`` (read with the default reading) with the mark set."""
    return _read(x).with_mark(True)


def unmark(x: Any) -> Value:
    """``x`` (read with the default reading) without the mark."""
    return _read(x).with_mark(False)


if sys.version_info < (3, 11):  # pragma: no cover
    raise ImportError("bassline needs Python 3.11 or later")
