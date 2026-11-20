"""The canonical encoding: an encoder and a resumable decoder.

The decoder tells apart bytes that are *wrong*, which it refuses with a
:class:`~bassline.errors.Reason`, from bytes that are only *the start of a
value*, which it waits on. Feed it bytes however they arrive and pull each
value as soon as its last byte is in::

    d = Decoder()
    for chunk in chunks:
        for v in d.feed(chunk):
            handle(v)
    for v in d.finish():       # raises Incomplete if input stopped inside a value
        handle(v)

It is a state machine over an explicit stack of open frames: no
recursion, so nesting never reaches the call stack, and feeding one byte at
a time gives the same values and the same refusals as feeding everything at
once.

Where a fault is reported
-------------------------
Each rule is judged at the first byte that can break it, and the decoder
refuses at the first byte that breaks any rule, so with several faults the
first in byte order wins, however the input was chunked:

- ``invalid-tag``, ``end-with-bits``, ``end-at-top``, ``length-bits``,
  ``too-deep``: the header (or END) byte.
- ``non-minimal-length``: the one-byte length, or the last of the four.
- ``bad-integer``, ``bad-utf8``: the first payload byte that no
  well-formed payload of the declared length could have there (the header,
  for an integer of length zero).
- ``empty-record``, ``stranded-key``: the END byte.
- ``out-of-order``: the first byte at which a set member or dict key falls
  below its predecessor, compared on the bytes as they arrive.
- ``duplicate``: the last byte of the repeated member or key.
- ``too-large``: the byte at which the value is known to pass the cap,
  counting a scalar's whole declared payload once its length is read.

At a single byte, a value's own rules are judged before its order against
its predecessor, and order before duplication.
"""

from __future__ import annotations

from collections import deque
from collections.abc import Iterable, Iterator
from typing import Any

from .errors import DecodeError, Incomplete, Reason
from .values import (
    MARK_BIT,
    Bytes,
    Dict,
    Integer,
    List,
    Nil,
    Record,
    Set,
    Symbol,
    Text,
    Value,
    _read,
)

__all__ = [
    "DEFAULT_MAX_DEPTH",
    "DEFAULT_MAX_VALUE_BYTES",
    "encode",
    "encode_all",
    "Decoder",
    "decode",
    "decode_all",
    "iterdecode",
]

#: Frames open at once. The spec asks every decoder to have a limit.
DEFAULT_MAX_DEPTH = 64
#: Bytes buffered toward one value. The encoding can state scalars up to
#: ~4 GiB; a receiver draws its own line at its boundary.
DEFAULT_MAX_VALUE_BYTES = 100 * 1024 * 1024

_LIST, _RECORD, _DICT, _SET = 6, 7, 8, 9
_NIL = Nil()
_NIL_MARKED = Nil(mark=True)
_NOKEY = object()

_INVALID_TAG = Reason.INVALID_TAG
_END_WITH_BITS = Reason.END_WITH_BITS
_END_AT_TOP = Reason.END_AT_TOP
_LENGTH_BITS = Reason.LENGTH_BITS
_NON_MINIMAL = Reason.NON_MINIMAL_LENGTH
_BAD_INTEGER = Reason.BAD_INTEGER
_BAD_UTF8 = Reason.BAD_UTF8
_EMPTY_RECORD = Reason.EMPTY_RECORD
_STRANDED_KEY = Reason.STRANDED_KEY
_OUT_OF_ORDER = Reason.OUT_OF_ORDER
_DUPLICATE = Reason.DUPLICATE
_TOO_DEEP = Reason.TOO_DEEP
_TOO_LARGE = Reason.TOO_LARGE


# ---------------------------------------------------------------- encoding


def encode(v: Any) -> bytes:
    """The canonical encoding of ``v`` (a host value is read with the
    default reading first)."""
    return _read(v).ce


def encode_all(values: Iterable[Any]) -> bytes:
    """Values one after another: a bare concatenation of CE (a ``.blb``)."""
    return b"".join(_read(v).ce for v in values)


# ------------------------------------------------------- payload checks


def _int_fault(buf, ps: int, lo: int, hi: int, n: int) -> int:
    """First index in ``lo:hi`` (relative to the payload at ``ps``) where an
    integer payload of length ``n`` stops being canonical, or -1."""
    if lo >= hi:
        return -1
    i = lo
    if i == 0:
        c = buf[ps]
        if c == 0x2D:  # '-'
            if n == 1:
                return 0
        elif c == 0x30:  # '0'
            if n > 1:
                return 0
        elif not 0x31 <= c <= 0x39:
            return 0
        i = 1
    if i == 1 and i < hi and buf[ps] == 0x2D:
        if not 0x31 <= buf[ps + 1] <= 0x39:
            return 1
        i = 2
    if i < hi:
        chunk = bytes(buf[ps + i:ps + hi])
        if not chunk.isdigit():
            for j, c in enumerate(chunk):
                if not 0x30 <= c <= 0x39:
                    return i + j
    return -1


def _utf8_lead(b0: int):
    """Continuation count and the allowed range of the first continuation
    for a lead byte, or None when ``b0`` can't start a sequence."""
    if b0 < 0x80:
        return 0, 0, 0
    if 0xC2 <= b0 <= 0xDF:
        return 1, 0x80, 0xBF
    if b0 == 0xE0:
        return 2, 0xA0, 0xBF
    if b0 == 0xED:
        return 2, 0x80, 0x9F
    if 0xE1 <= b0 <= 0xEF:
        return 2, 0x80, 0xBF
    if b0 == 0xF0:
        return 3, 0x90, 0xBF
    if 0xF1 <= b0 <= 0xF3:
        return 3, 0x80, 0xBF
    if b0 == 0xF4:
        return 3, 0x80, 0x8F
    return None


def _utf8_fault(buf, ps: int, lo: int, hi: int, n: int) -> tuple[int, int]:
    """Check payload bytes ``lo:hi`` (relative to ``ps``) of a UTF-8
    payload of length ``n``, where ``lo`` starts a sequence. Returns the
    first index no well-formed payload of length ``n`` could have there
    (or -1), and where a later check should resume."""
    if lo >= hi:
        return -1, lo
    try:
        bytes(buf[ps + lo:ps + hi]).decode("utf-8")
        return -1, hi
    except UnicodeDecodeError as e:
        i = lo + e.start
    while i < hi:
        lead = _utf8_lead(buf[ps + i])
        if lead is None:
            return i, i
        need, first_lo, first_hi = lead
        if need == 0:
            i += 1
            continue
        if i + need >= n:  # the sequence would run past the payload
            return i, i
        for j in range(1, need + 1):
            if i + j >= hi:
                return -1, i  # unfinished: resume at its lead
            c = buf[ps + i + j]
            if j == 1:
                ok = first_lo <= c <= first_hi
            else:
                ok = 0x80 <= c <= 0xBF
            if not ok:
                return i + j, i
        i += need + 1
    return -1, hi


def _mismatch(a: bytes, b: bytes) -> int:
    """Index of the first difference between ``a`` and ``b`` (which differ
    within their common length, or one is shorter)."""
    n = min(len(a), len(b))
    if a[:n] == b[:n]:
        return n
    lo, hi = 0, n
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if a[lo:mid] == b[lo:mid]:
            lo = mid
        else:
            hi = mid
    return lo


# ---------------------------------------------------------------- decoding


class _Open:
    """A frame whose END hasn't arrived."""

    __slots__ = ("kind", "mark", "start", "items", "key",
                 "prev_lo", "prev_hi", "cur", "equal")

    def __init__(self, kind: int, mark: bool, start: int):
        self.kind = kind
        self.mark = mark
        self.start = start
        self.items: list = []
        self.key = _NOKEY        # a dict key waiting for its value
        self.prev_lo = -1        # bytes of the previous set member / dict key
        self.prev_hi = -1
        self.cur = -1            # start of the member / key in progress
        self.equal = False       # whether it still equals its predecessor so far

    def build(self) -> Value:
        k = self.kind
        if k == _LIST:
            return List._trusted(tuple(self.items), self.mark)
        if k == _RECORD:
            return Record._trusted(tuple(self.items), self.mark)
        if k == _SET:
            return Set._trusted(self.items, self.mark)
        return Dict._trusted(dict(self.items), self.mark)


class Decoder:
    """Decodes back-to-back canonically encoded values, however
    the bytes arrive.

    ``feed(data)`` buffers bytes and returns the decoder; iterating it yields
    each value that has completed, then raises :class:`DecodeError` if the
    bytes after them are wrong, or stops when more bytes are needed.
    ``finish()`` declares the end of input: iterating what it returns raises
    :class:`Incomplete` if a value was left unfinished. Once a decoder has
    refused, it raises the same error forever; the encoding has nothing to
    resynchronise on.

    ``max_depth`` refuses frames nested past it (``too-deep``);
    ``max_value_bytes`` refuses a value whose bytes would pass it
    (``too-large``), judged as soon as a header or length says so.
    """

    def __init__(self, *, max_depth: int = DEFAULT_MAX_DEPTH,
                 max_value_bytes: int = DEFAULT_MAX_VALUE_BYTES):
        self.max_depth = max_depth
        self.max_value_bytes = max_value_bytes
        self._buf = bytearray()
        self._pos = 0            # first byte not yet part of a landed value or open frame
        self._base = 0           # input offset of _buf[0]
        self._stack: list[_Open] = []
        self._vstart = 0         # start of the outermost value in progress
        self._ready: deque[Value] = deque()
        self._failure: BaseException | None = None
        self._finished = False
        self._n_equal = 0        # open frames whose current member still equals its predecessor
        self._item = -1          # start of a scalar seen in part, if any
        self._item_cmp = 0       # how far that scalar's bytes have been compared
        self._item_chk = 0       # how far its payload has been checked (relative)

    # -- the surface

    def feed(self, data: bytes | bytearray | memoryview) -> Decoder:
        """Buffer ``data`` and decode as far as it goes. Returns ``self``,
        so ``for v in decoder.feed(chunk)`` reads naturally."""
        if self._finished:
            raise ValueError("feed() after finish()")
        if self._failure is None and data:
            self._compact()
            self._buf += data
            self._run()
        return self

    def finish(self) -> Decoder:
        """Declare the end of input. Returns ``self``: iterate it for any
        values not yet taken; iteration raises :class:`Incomplete` after
        them if the input stopped inside a value."""
        self._finished = True
        if self._failure is None and self.pending:
            self._failure = Incomplete(
                "input ended inside a value that began at byte "
                f"{self._base + self._unfinished_start()}",
                self._base + len(self._buf))
        return self

    def __iter__(self) -> Iterator[Value]:
        return self

    def __next__(self) -> Value:
        if self._ready:
            return self._ready.popleft()
        if self._failure is not None:
            raise self._failure
        raise StopIteration

    @property
    def pending(self) -> bool:
        """Whether bytes of an unfinished value are buffered."""
        return bool(self._stack) or self._pos < len(self._buf)

    @property
    def offset(self) -> int:
        """Input offset of the first byte not yet part of a value."""
        return self._base + self._pos

    # -- the machine

    def _unfinished_start(self) -> int:
        return self._stack[0].start if self._stack else self._pos

    def _compact(self) -> None:
        k = self._pos
        if self._stack or k == 0 or k * 2 < len(self._buf):
            return
        del self._buf[:k]
        self._base += k
        self._pos = 0
        if self._item >= 0:
            self._item -= k
            self._item_cmp -= k

    def _fail(self, reason: Reason, at: int):
        err = DecodeError(reason, self._base + at)
        self._failure = err
        raise err

    def _run(self) -> None:
        try:
            self._advance()
        except DecodeError:
            pass  # recorded; raised after the values that came before it

    def _advance(self) -> None:
        buf = self._buf
        n = len(buf)
        stack = self._stack
        cap = self.max_value_bytes
        while self._pos < n:
            p = self._pos
            if not stack:
                self._vstart = p
            vs = self._vstart
            h = buf[p]
            tag = h >> 4
            if tag == 0xA:
                if h != 0xA0:
                    self._fail(_END_WITH_BITS, p)
                if not stack:
                    self._fail(_END_AT_TOP, p)
                if p + 1 - vs > cap:
                    self._fail(_TOO_LARGE, p)
                top = stack[-1]
                if top.kind == _RECORD and not top.items:
                    self._fail(_EMPTY_RECORD, p)
                if top.kind == _DICT and top.key is not _NOKEY:
                    self._fail(_STRANDED_KEY, p)
                if self._n_equal:
                    self._compare(p, p + 1, len(stack) - 1)
                stack.pop()
                self._pos = p + 1
                self._land(top.build(), top.start, p)
                continue
            if tag == 0 or tag > 9:
                self._fail(_INVALID_TAG, p)
            if tag == 1 or tag >= 6:
                if h & 7:
                    self._fail(_LENGTH_BITS, p)
                if p + 1 - vs > cap:
                    self._fail(_TOO_LARGE, p)
                if tag >= 6 and len(stack) >= self.max_depth:
                    self._fail(_TOO_DEEP, p)
                if stack:
                    self._begin(p)
                if self._n_equal:
                    self._compare(p, p + 1, len(stack))
                self._pos = p + 1
                if tag == 1:
                    self._land(_NIL_MARKED if h & MARK_BIT else _NIL, p, p)
                else:
                    stack.append(_Open(tag, bool(h & MARK_BIT), p))
                continue
            done = self._scalar(p, h, tag, n, vs)
            if done is None:
                return
            v, end = done
            self._pos = end
            self._land(v, p, end - 1)

    def _scalar(self, p: int, h: int, tag: int, n: int, vs: int):
        """Decode the scalar at ``p`` as far as the buffer goes: its value
        and end once complete, ``None`` while waiting."""
        buf = self._buf
        stack = self._stack
        cap = self.max_value_bytes
        if self._item != p:
            self._item = p
            self._item_cmp = p
            self._item_chk = 0
            if stack:
                self._begin(p)
        lb = h & 7
        f = -1
        why = None
        hl = plen = known = -1
        if p + 1 - vs > cap:
            f, why = p, _TOO_LARGE
        elif tag == 2 and lb == 0:
            f, why = p, _BAD_INTEGER
        elif lb < 7:
            hl, plen, known = 1, lb, p
        elif p + 1 < n:
            m = buf[p + 1]
            if m < 7:
                f, why = p + 1, _NON_MINIMAL
            elif m < 255:
                hl, plen, known = 2, m, p + 1
            elif p + 5 < n:
                big = int.from_bytes(buf[p + 2:p + 6], "big")
                if big < 255:
                    f, why = p + 5, _NON_MINIMAL
                else:
                    hl, plen, known = 6, big, p + 5
        end = -1
        text = None
        if f < 0 and plen >= 0:
            end = p + hl + plen
            if end - vs > cap:
                f, why = known, _TOO_LARGE
            else:
                ps = p + hl
                avail = min(n, end) - ps
                lo = self._item_chk
                if tag == 2:
                    q = _int_fault(buf, ps, lo, avail, plen)
                    self._item_chk = avail
                    if q >= 0:
                        f, why = ps + q, _BAD_INTEGER
                elif tag != 5:
                    if lo == 0 and avail == plen:
                        try:
                            text = bytes(buf[ps:end]).decode("utf-8")
                        except UnicodeDecodeError:
                            pass
                    if text is None:
                        q, self._item_chk = _utf8_fault(buf, ps, lo, avail, plen)
                        if q >= 0:
                            f, why = ps + q, _BAD_UTF8
        upto = f if f >= 0 else (min(n, end) if end >= 0 else n)
        if self._n_equal and upto > self._item_cmp:
            self._compare(self._item_cmp, upto, len(stack))
        if upto > self._item_cmp:
            self._item_cmp = upto
        if f >= 0:
            self._fail(why, f)
        if end < 0 or end > n:
            return None
        self._item = -1
        ce = bytes(buf[p:end])
        if tag == 2:
            v = Integer._from_ce(ce)
        elif tag == 5:
            v = Bytes._trusted(ce[hl:], ce)
        else:
            if text is None:
                text = ce[hl:].decode("utf-8")
            v = (Text if tag == 3 else Symbol)._trusted(text, ce)
        return v, end

    def _begin(self, p: int) -> None:
        """A constituent of the top frame starts at ``p``."""
        top = self._stack[-1]
        k = top.kind
        if k == _SET or (k == _DICT and top.key is _NOKEY):
            top.cur = p
            if top.prev_lo >= 0:
                top.equal = True
                self._n_equal += 1

    def _compare(self, lo: int, hi: int, count: int) -> None:
        """Compare bytes ``lo:hi`` of every member in progress (in the
        outermost ``count`` frames) that still equals its predecessor."""
        buf = self._buf
        worst = -1
        for i in range(count):
            f = self._stack[i]
            if not f.equal:
                continue
            plo = f.prev_lo + (lo - f.cur)
            a = buf[lo:hi]
            b = buf[plo:min(plo + (hi - lo), f.prev_hi)]
            if a == b:
                continue
            j = _mismatch(a, b)
            if j < len(b) and a[j] < b[j]:
                at = lo + j
                if worst < 0 or at < worst:
                    worst = at
            else:
                f.equal = False
                self._n_equal -= 1
        if worst >= 0:
            self._fail(_OUT_OF_ORDER, worst)

    def _land(self, v: Value, start: int, last: int) -> None:
        """A value whose bytes are ``start..last`` is complete."""
        stack = self._stack
        if not stack:
            self._ready.append(v)
            return
        top = stack[-1]
        k = top.kind
        if k == _SET or (k == _DICT and top.key is _NOKEY):
            if top.equal:
                self._fail(_DUPLICATE, last)
            top.prev_lo, top.prev_hi = start, last + 1
            if v._ce is None:  # a frame: its bytes are here, and it will be hashed
                object.__setattr__(v, "_ce", bytes(self._buf[start:last + 1]))
            if k == _SET:
                top.items.append(v)
            else:
                top.key = v
        elif k == _DICT:
            top.items.append((top.key, v))
            top.key = _NOKEY
        else:
            top.items.append(v)


def _one_shot(data, max_depth: int, max_value_bytes: int | None,
              out: list[Value]) -> list[Value]:
    cap = DEFAULT_MAX_VALUE_BYTES if max_value_bytes is None else max_value_bytes
    if max_value_bytes is None:
        cap = max(cap, len(data))  # the caller already holds these bytes
    d = Decoder(max_depth=max_depth, max_value_bytes=cap)
    out.extend(d.feed(data))
    out.extend(d.finish())
    return out


def decode_all(data: bytes | bytearray | memoryview, *,
               max_depth: int = DEFAULT_MAX_DEPTH,
               max_value_bytes: int | None = None) -> list[Value]:
    """Every value in ``data``, which must end on a value boundary
    (:class:`Incomplete` otherwise). The byte cap defaults to at least the
    input's length, since the caller already holds it."""
    return _one_shot(data, max_depth, max_value_bytes, [])


def decode(data: bytes | bytearray | memoryview, *,
           max_depth: int = DEFAULT_MAX_DEPTH,
           max_value_bytes: int | None = None) -> Value:
    """Exactly one value. The input is judged as a whole first, as the
    reader judges a document: a fault anywhere raises :class:`DecodeError`,
    input that stops inside any value (including no bytes at all) raises
    :class:`Incomplete`, and only then do whole values after the first
    raise ``trailing-bytes``."""
    values = _one_shot(data, max_depth, max_value_bytes, [])
    if not values:
        raise Incomplete("no value: the input is empty", 0)
    if len(values) > 1:
        raise DecodeError(Reason.TRAILING_BYTES, len(values[0].ce))
    return values[0]


def iterdecode(chunks: Iterable[bytes], *,
               max_depth: int = DEFAULT_MAX_DEPTH,
               max_value_bytes: int = DEFAULT_MAX_VALUE_BYTES) -> Iterator[Value]:
    """Each value from an iterable of byte chunks, as soon as it completes.
    For unbuffered reading of a file descriptor::

        for v in iterdecode(iter(lambda: os.read(fd, 65536), b"")): ...
    """
    d = Decoder(max_depth=max_depth, max_value_bytes=max_value_bytes)
    for chunk in chunks:
        yield from d.feed(chunk)
    yield from d.finish()
