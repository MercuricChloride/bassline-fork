"""A seeded generator of random values, and an independent model of
canonical order and of prefixes to check the implementation against."""

from __future__ import annotations

import random

import _path  # noqa: F401  (puts src on sys.path)
from bassline import (
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
    decode,
)

# pieces of awkward text: escapes, quotes, delimiters, NFC and NFD, combining
# marks, controls, CRLF, non-BMP, invisible separators
SCALARS = [
    "a", "b", "z", "A", " ", "\n", "\r", "\r\n", "\t", "\\", '"', "'", "!", ":",
    ";", "[", "]", "{", "}", "(", ")", "0", "5", "-", "_", "x", "\u00e9", "e\u0301",
    "\u0301", "\U0001F600", "\u0000", "\u0007", "\u007f", "\u00a0", "\u2028", "\ufeff",
    "\U0010FFFF", "nil",
]
NAMES = ["", "nil", "go", "a b", "0x", "0x12", "5", "-5", "-", "->", "+5", "_5",
         "nilx", "\u00e9", "0", "-0", "1_0", "a!b", "a:b", "'", '"', "x\u00a0y"]
BOUNDARY_INTS = [0, 1, -1, 9, 10, -10, 2**63 - 1, -2**63, 2**63, -2**63 - 1,
                 2**64, 2**64 - 1, 10**18, -10**18]
TIER_LENGTHS = [0, 1, 6, 7, 8, 254, 255, 256]


class Gen:
    def __init__(self, seed: int):
        self.r = random.Random(seed)

    def chance(self, n: int) -> bool:
        return self.r.randrange(n) == 0

    def text(self) -> str:
        r = self.r
        if self.chance(15):
            # an ASCII run whose UTF-8 length sits on a length-tier edge
            return "q" * r.choice(TIER_LENGTHS)
        n = r.randint(200, 300) if self.chance(20) else r.randint(0, 10)
        return "".join(r.choice(SCALARS) for _ in range(n))

    def integer(self) -> int:
        r = self.r
        pick = r.randrange(6)
        if pick == 0:
            return r.choice(BOUNDARY_INTS)
        if pick == 1:
            return r.randint(-2**63, 2**63 - 1)
        if pick == 2:
            return r.randint(-1000, 1000)
        if pick == 3:
            return r.randint(-10**40, 10**40)
        if pick == 4 and self.chance(10):
            # past Python's int-to-str digit limit (4300)
            return r.choice((1, -1)) * r.randint(10**4400, 10**4401)
        return r.randint(-10, 10)

    def bytes_(self) -> bytes:
        r = self.r
        n = r.choice(TIER_LENGTHS) if self.chance(5) else r.randint(0, 9)
        return bytes(r.randrange(256) for _ in range(n))

    def value(self, depth: int = 0, max_depth: int = 3) -> Value:
        r = self.r
        kinds = list(Kind) if depth < max_depth else [k for k in Kind if k < 6]
        k = r.choice(kinds)
        mark = self.chance(4)
        members = lambda: [self.value(depth + 1, max_depth) for _ in range(r.randint(0, 4))]
        if k == Kind.NIL:
            return Nil(mark=mark)
        if k == Kind.INTEGER:
            return Integer(self.integer(), mark=mark)
        if k == Kind.TEXT:
            return Text(self.text(), mark=mark)
        if k == Kind.SYMBOL:
            return Symbol(r.choice(NAMES) if self.chance(2) else self.text(), mark=mark)
        if k == Kind.BYTES:
            return Bytes(self.bytes_(), mark=mark)
        if k == Kind.LIST:
            return List(members(), mark=mark)
        if k == Kind.RECORD:
            return Record(self.value(depth + 1, max_depth), *members(), mark=mark)
        if k == Kind.DICT:
            keys = Set(members())  # unique keys
            return Dict({key: self.value(depth + 1, max_depth) for key in keys}, mark=mark)
        return Set(members(), mark=mark)

    def values(self, n: int, max_depth: int = 3) -> list[Value]:
        return [self.value(0, max_depth) for _ in range(n)]


# ---------------------------------------------------------- a model of order


def payload(v: Value) -> bytes:
    """A scalar's payload, computed from the host reading, not from CE."""
    k = v.kind
    if k == Kind.INTEGER:
        return str(v.value).encode() if abs(v.value) < 10**4000 else v.spelling.encode()
    if k in (Kind.TEXT, Kind.SYMBOL):
        return v.value.encode("utf-8")
    if k == Kind.BYTES:
        return v.value
    return b""


def constituents(v: Value) -> list[Value]:
    if v.kind == Kind.DICT:
        return [x for kv in v.items() for x in kv]
    if v.kind >= 6:
        return list(v)
    return []


def ref_cmp(a: Value, b: Value) -> int:
    """Canonical order written out structurally, as the spec describes it:
    kind, then mark, then for scalars shorter payloads first and then
    bytewise, then for frames member by member, with a shorter frame after
    a longer one it prefixes."""
    if a.kind != b.kind:
        return -1 if a.kind < b.kind else 1
    if a.mark != b.mark:
        return -1 if not a.mark else 1
    if a.kind < 6:
        pa, pb = payload(a), payload(b)
        if len(pa) != len(pb):
            return -1 if len(pa) < len(pb) else 1
        return (pa > pb) - (pa < pb)
    ma, mb = constituents(a), constituents(b)
    for x, y in zip(ma, mb):
        c = ref_cmp(x, y)
        if c:
            return c
    if len(ma) == len(mb):
        return 0
    return 1 if len(ma) < len(mb) else -1  # the shorter one sorts after


# ------------------------------------------------------- a model of prefixes


def item_boundaries(ce: bytes) -> list[tuple[int, int]]:
    """Each position in ``ce`` just after a whole item (a frame header, an
    END, a whole nil or scalar), with how many frames are open there."""
    out = []
    i = depth = 0
    while i < len(ce):
        h = ce[i]
        tag, lb = h >> 4, h & 7
        if h == 0xA0:
            depth -= 1
            i += 1
        elif tag == 1:
            i += 1
        elif tag >= 6:
            depth += 1
            i += 1
        else:
            if lb < 7:
                hl, n = 1, lb
            elif ce[i + 1] < 255:
                hl, n = 2, ce[i + 1]
            else:
                hl, n = 6, int.from_bytes(ce[i + 2:i + 6], "big")
            i += hl + n
        out.append((i, depth))
    return out


def truncation_prefixes(v: Value) -> list[Value]:
    """Every value that ``v``'s encoding yields when stopped after some
    whole item, with each frame left open closed by END."""
    ce = v.ce
    out = []
    for k, depth in item_boundaries(ce):
        try:
            out.append(decode(ce[:k] + b"\xa0" * depth))
        except ValueError:
            pass  # not a value (a stranded key, a record with no head)
    return out
