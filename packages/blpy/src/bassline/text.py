"""The textual syntax: a printer and a resumable reader.

The syntax is ``data-model.org``'s. It is a human form that compiles to
values, not an encoding: it carries no identity of its own.

Reading tells apart text that is *refused* (:class:`ReadError`) from text
that is *incomplete* (:class:`Incomplete`: it stopped where more could still
make it valid, as in ``[1 2``). :func:`read` wants exactly one value,
:func:`read_all` a whole document, and :class:`Reader` takes text however
it arrives and hands over each value as soon as its text is complete::

    r = Reader()
    for chunk in chunks:           # str, or UTF-8 bytes
        for v in r.feed(chunk):
            handle(v)
    for v in r.finish():           # the last atom completes at end of input
        handle(v)

A frame is complete at its closing bracket. An atom is complete at the
delimiter after it, since ``12`` could still become ``123`` and ``go!``
could still turn out to be the error ``go!b``; at end of input, ``finish``
completes it. A ``!`` touching a frame that has just closed is refused when
it arrives, after the frame was handed over, as the decoder refuses a stray
END after a value.
"""

from __future__ import annotations

import codecs
import re
from collections import deque
from collections.abc import Iterable, Iterator

from .errors import Incomplete, NotHeld, ReadError
from .values import (
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
    _ce_key,
    _parse,
)

__all__ = [
    "to_text",
    "pretty",
    "read",
    "read_all",
    "Reader",
    "iter_read",
    "bl",
    "DEFAULT_MAX_DEPTH",
]

DEFAULT_MAX_DEPTH = 64

_WS = " \t\n\r"
_DELIMS = frozenset(" \t\n\r[](){}:!'\";")
_OPENERS = "([{"
_CLOSERS = {")": 7, "]": 6, "}": 0}
_DIGITS = frozenset("0123456789")
_ESCAPES = frozenset("\\ntr")   # and the closing quote
_HEX = frozenset("0123456789abcdefABCDEF")

_RE_WS = re.compile(r"[ \t\n\r]*")
_RE_BARE = re.compile(r"[^ \t\n\r\[\](){}:!'\";]*")
_RE_INT = re.compile(r"0|-?[1-9][0-9]*")
_RE_GAP = re.compile(r"(?:[ \t\n\r]+|;[^\n]*)*")   # whitespace and comments

# ---------------------------------------------------------------- printing

_ESC_TEXT = str.maketrans({"\\": "\\\\", "\n": "\\n", "\t": "\\t",
                           "\r": "\\r", '"': '\\"'})
_ESC_SYM = str.maketrans({"\\": "\\\\", "\n": "\\n", "\t": "\\t",
                          "\r": "\\r", "'": "\\'"})


def _is_bare(s: str) -> bool:
    """Whether a symbol may be printed without quotes and read back as
    itself: not empty, not ``nil``, not number-like, and nothing in it a
    delimiter, a control character or whitespace."""
    if not s or s == "nil":
        return False
    c = s[0]
    if c in _DIGITS or (c == "-" and len(s) > 1 and s[1] in _DIGITS):
        return False
    for ch in s:
        if ch in _DELIMS or ch.isspace() or ord(ch) < 0x20 or ord(ch) == 0x7F:
            return False
    return True


def _atom_text(v: Value) -> str:
    k = v.kind
    if k == 1:
        t = "nil"
    elif k == 2:
        t = v.spelling
    elif k == 3:
        t = '"' + v._s.translate(_ESC_TEXT) + '"'
    elif k == 4:
        s = v._s
        t = s if _is_bare(s) else "'" + s.translate(_ESC_SYM) + "'"
    else:
        t = "0x" + v._b.hex()
    return t + "!" if v._mark else t


def _opener(v: Value) -> str:
    o = "[" if v.kind == 6 else "(" if v.kind == 7 else "{"
    return "!" + o if v._mark else o


def _closer(v: Value) -> str:
    return "]" if v.kind == 6 else ")" if v.kind == 7 else "}"


def to_text(v: Value) -> str:
    """``v`` in the textual syntax on one line; ``str(v)`` is this."""
    out: list[str] = []
    work: list = [v]
    while work:
        x = work.pop()
        if x.__class__ is str:
            out.append(x)
            continue
        k = x.kind
        if k < 6:
            out.append(_atom_text(x))
            continue
        if k == 8:
            d = x._d
            if not d:
                out.append("!{:}" if x._mark else "{:}")
                continue
            out.append(_opener(x))
            work.append("}")
            items = list(d.items())
            for i in range(len(items) - 1, -1, -1):
                key, val = items[i]
                work.append(val)
                work.append(": ")
                work.append(key)
                if i:
                    work.append(" ")
            continue
        members = x._m if k != 9 else tuple(x._d)
        out.append(_opener(x))
        work.append(_closer(x))
        for i in range(len(members) - 1, -1, -1):
            work.append(members[i])
            if i:
                work.append(" ")
    return "".join(out)


def _members(v: Value) -> tuple:
    k = v.kind
    if k in (6, 7):
        return v._m
    if k == 9:
        return tuple(v._d)
    return ()


def _flat_len(v: Value, room: int) -> int:
    """Width of the one-line spelling, stopping early (before descending
    any further) once it is past ``room``."""
    if v.kind < 6:
        return len(_atom_text(v))
    n = len(_opener(v)) + 1
    if v.kind == 8:
        if not v._d:
            return n + 1
        first = True
        for key, val in v._d.items():
            if n > room:
                return n
            if not first:
                n += 1
            first = False
            n += _flat_len(key, room - n) + 2
            if n > room:
                return n
            n += _flat_len(val, room - n)
        return n
    first = True
    for m in _members(v):
        if n > room:
            return n
        if not first:
            n += 1
        first = False
        n += _flat_len(m, room - n)
    return n


class _Out:
    __slots__ = ("parts", "col")

    def __init__(self):
        self.parts: list[str] = []
        self.col = 0

    def add(self, s: str) -> None:
        self.parts.append(s)
        nl = s.rfind("\n")
        self.col = len(s) - nl - 1 if nl >= 0 else self.col + len(s)

    def newline(self, align: int) -> None:
        self.add("\n" + " " * align)


def _put_members(o: _Out, ms: tuple, skip: int, align: int, width: int,
                 trail: int, depth: int) -> None:
    n = len(ms)
    fill = all(m.kind < 6 for m in ms[skip:])
    for i in range(skip, n):
        m = ms[i]
        after = 1 + trail if i == n - 1 else 0
        if i > skip:
            if fill and o.col + 1 + len(_atom_text(m)) + after <= width:
                o.add(" ")
            else:
                o.newline(align)
        _put(o, m, width, after, depth + 1)


def _put(o: _Out, v: Value, width: int, trail: int, depth: int) -> None:
    """``v`` at the current column: on one line when it fits with
    ``trail`` closers still to come, otherwise opened up."""
    if v.kind < 6 or len(v) == 0 or depth > 200:
        o.add(to_text(v))
        return
    col = o.col
    if col + _flat_len(v, width - col - trail) + trail <= width:
        o.add(to_text(v))
        return
    o.add(_opener(v))
    if v.kind == 8:
        align = o.col
        items = list(v._d.items())
        for i, (key, val) in enumerate(items):
            if i:
                o.newline(align)
            _put(o, key, width, 2, depth + 1)
            o.add(": ")
            _put(o, val, width, 1 + trail if i == len(items) - 1 else 0, depth + 1)
    elif v.kind == 7:
        ms = v._m
        only = len(ms) == 1
        _put(o, ms[0], width, 1 + trail if only else 0, depth + 1)
        if not only:
            align = o.col + 1
            if align > width // 2:
                align = col + len(_opener(v))
                o.newline(align)
            else:
                o.add(" ")
            _put_members(o, ms, 1, align, width, trail, depth)
    else:
        _put_members(o, _members(v), 0, o.col, width, trail, depth)
    o.add(_closer(v))


def pretty(v: Value, width: int = 80) -> str:
    """``v`` laid out within ``width`` columns where it can be: frames that
    fit stay on one line, others open up with their members aligned."""
    o = _Out()
    _put(o, v, width, 0, 0)
    return "".join(o.parts)


# ---------------------------------------------------------------- reading


class _Frame:
    __slots__ = ("kind", "mark", "start", "items", "state", "key", "seen")

    # brace states
    OPEN, COLON_FIRST, FIRST, SET, KEY, COLON, VALUE = range(7)

    def __init__(self, kind: int, mark: bool, start: int):
        self.kind = kind          # 6 list, 7 record, 0 braces (set or dict)
        self.mark = mark
        self.start = start
        self.items: list = []
        self.state = _Frame.OPEN
        self.key = None
        self.seen: dict | None = None


class _Tok:
    """An atom whose text is still arriving: its pieces so far, from its
    first character (a quoted atom's opening quote included)."""

    __slots__ = ("start", "q", "parts", "escape", "done", "line", "col")

    def __init__(self, start: int, q: str):
        self.start = start
        self.q = q                # the quote, or "" for a bare run
        self.parts: list[str] = []
        self.escape = False       # the text so far ends inside an escape
        self.done = False         # the text is whole; waiting to see a mark after it
        self.line = None          # where it starts, kept once its start is dropped
        self.col = None


def _escape_body(body: str, q: str):
    """Undo escapes in a quoted body: the text and -1, or None and the
    index of an unknown escape's backslash."""
    if "\\" not in body:
        return body, -1
    out = []
    i = 0
    n = len(body)
    while i < n:
        j = body.find("\\", i)
        if j < 0:
            out.append(body[i:])
            break
        out.append(body[i:j])
        e = body[j + 1]
        if e == q or e == "\\":
            out.append(e)
        elif e == "n":
            out.append("\n")
        elif e == "t":
            out.append("\t")
        elif e == "r":
            out.append("\r")
        else:
            return None, j
        i = j + 2
    return "".join(out), -1


class Reader:
    """Reads values from text however it arrives.

    ``feed(text)`` takes a ``str`` or UTF-8 ``bytes`` and returns the
    reader; iterating it yields each value whose text is complete, then
    raises :class:`ReadError` if the text after them is refused, or stops
    when more is needed. ``finish()`` declares the end of input: iterating
    what it returns yields any last atom, then raises :class:`Incomplete` if
    the text stopped inside a value. Once it has refused, it raises the same
    error forever.
    """

    def __init__(self, *, max_depth: int = DEFAULT_MAX_DEPTH):
        self.max_depth = max_depth
        self._buf = ""
        self._pos = 0
        self._base = 0               # offset of _buf[0] in the whole input
        self._lines = 0              # newlines in text dropped from _buf
        self._line_start = 0         # offset just after the last dropped newline
        self._stack: list[_Frame] = []
        self._ready: deque[tuple[Value, int, int]] = deque()  # value, start, end
        self._failure: BaseException | None = None
        self._finished = False
        self._final = False
        self._tok: _Tok | None = None  # an atom whose text is still arriving
        self._in_comment = False
        self._after_frame = False    # the last token closed a frame, touching what follows
        self._utf8 = None            # incremental decoder, once bytes arrive

    # -- the surface

    def feed(self, text: str | bytes | bytearray | memoryview) -> Reader:
        """Buffer ``text`` and read as far as it goes. Returns ``self``."""
        if self._finished:
            raise ValueError("feed() after finish()")
        if self._failure is not None:
            return self
        if not isinstance(text, str):
            if self._utf8 is None:
                self._utf8 = codecs.getincrementaldecoder("utf-8")("strict")
            try:
                text = self._utf8.decode(bytes(text))
            except UnicodeDecodeError:
                self._compact()
                self._fault("malformed UTF-8 in the input", self._base + len(self._buf))
                return self
        elif self._utf8 is not None and self._utf8.getstate()[0]:
            self._fault("text arrived inside a UTF-8 sequence", self._base + len(self._buf))
            return self
        if text:
            self._compact()
            self._buf = self._buf + text if self._buf else text
            self._run()
        return self

    def finish(self) -> Reader:
        """Declare the end of input. Returns ``self``: iterate it for the
        last values; iteration raises :class:`Incomplete` after them if the
        text stopped inside a value."""
        if self._finished:
            return self
        self._finished = True
        self._final = True
        if self._failure is not None:
            return self
        if self._utf8 is not None:
            try:
                self._utf8.decode(b"", final=True)
            except UnicodeDecodeError:
                self._incomplete("the input ended inside a UTF-8 sequence")
                return self
        self._run()
        if self._failure is None and self._stack:
            f = self._stack[-1]
            opener = "(" if f.kind == 7 else "[" if f.kind == 6 else "{"
            self._incomplete(f"unclosed {opener} at {self._where_text(f.start)}")
        return self

    def __iter__(self) -> Iterator[Value]:
        return self

    def __next__(self) -> Value:
        return self._pull()[0]

    def _pull(self) -> tuple[Value, int, int]:
        if self._ready:
            return self._ready.popleft()
        if self._failure is not None:
            raise self._failure
        raise StopIteration

    @property
    def pending(self) -> bool:
        """Whether text of an unfinished value is buffered."""
        return bool(self._stack) or self._tok is not None or self._pos < len(self._buf)

    # -- positions and faults

    def _where(self, at: int) -> tuple[int, int]:
        """Line and column (1-based) of input offset ``at``."""
        if at >= self._base:
            head = self._buf[:at - self._base]
            nl = head.count("\n")
            line_start = self._base + head.rfind("\n") + 1 if nl else self._line_start
            return self._lines + nl + 1, at - line_start + 1
        tok = self._tok
        if tok is not None and tok.line is not None and at >= tok.start:
            # inside an atom whose start has been dropped: count from its start
            text = "".join(tok.parts)[:at - tok.start]
            nl = text.count("\n")
            if nl:
                return tok.line + nl, at - (tok.start + text.rfind("\n") + 1) + 1
            return tok.line, tok.col + at - tok.start
        return self._lines + 1, max(1, at - self._line_start + 1)

    def _where_text(self, at: int) -> str:
        if at < self._base:
            return f"offset {at}"
        line, col = self._where(at)
        return f"line {line}, column {col}"

    def _fault(self, msg: str, at: int) -> None:
        line, col = self._where(at)
        self._failure = ReadError(msg, at, line, col)

    def _refuse(self, msg: str, at: int):
        self._fault(msg, at)
        raise self._failure

    def _incomplete(self, msg: str) -> None:
        at = self._base + len(self._buf)
        line, col = self._where(at)
        self._failure = Incomplete(msg, at, line, col)

    def _compact(self) -> None:
        k = self._pos
        if k == 0 or k * 2 < len(self._buf):
            return
        tok = self._tok
        if tok is not None and tok.line is None and tok.start < self._base + k:
            tok.line, tok.col = self._where(tok.start)
        dropped = self._buf[:k]
        nl = dropped.count("\n")
        if nl:
            self._lines += nl
            self._line_start = self._base + dropped.rfind("\n") + 1
        self._buf = self._buf[k:]
        self._base += k
        self._pos = 0

    # -- the machine

    def _run(self) -> None:
        try:
            self._advance()
        except ReadError:
            pass  # recorded; raised after the values that came before it

    def _advance(self) -> None:
        buf = self._buf
        n = len(buf)
        final = self._final
        while True:
            pos = self._pos
            tok = self._tok
            if tok is not None:
                if not tok.done:
                    end = (self._scan_quote if tok.q else self._scan_bare)(tok, buf, pos)
                    if end < 0:
                        self._pos = n
                        if not final:
                            return
                        if tok.q:
                            what = "text" if tok.q == '"' else "quoted symbol"
                            self._incomplete(f"an unterminated {what}")
                            return
                        end = n
                    tok.done = True
                    self._pos = pos = end
                # a mark behind the atom must touch it and end at a delimiter
                marked = False
                if pos < n and buf[pos] == "!":
                    if pos + 1 < n:
                        if buf[pos + 1] not in _DELIMS:
                            self._refuse("a marked atom ends at a delimiter",
                                         self._base + pos + 1)
                    elif not final:
                        return
                    marked = True
                    pos += 1
                elif pos >= n and not final:
                    return
                v = self._atom(tok)
                if marked:
                    v = v.with_mark(True)
                self._tok = None
                self._pos = pos
                self._land(v, tok.start, self._base + pos)
                continue
            if self._in_comment:
                j = buf.find("\n", pos)
                if j < 0:
                    self._pos = n
                    return
                self._in_comment = False
                self._pos = pos = j + 1
            if pos >= n:
                return
            c = buf[pos]
            if c in _WS:
                self._pos = _RE_WS.match(buf, pos).end()
                self._after_frame = False
                continue
            if c == ";":
                self._in_comment = True
                self._after_frame = False
                continue
            at = self._base + pos
            if c == "!":
                if self._after_frame:
                    self._refuse("a frame is marked in front, as !(…), not behind", at)
                if pos + 1 >= n:
                    if final:
                        self._incomplete("a mark waiting for its frame")
                    return
                d = buf[pos + 1]
                if d == "!":
                    self._refuse("a repeated mark", at + 1)
                if d in _WS or d == ";":
                    self._refuse("a mark separated from its value", at)
                if d not in _OPENERS:
                    self._refuse("an atom is marked behind, as x!, not in front", at)
                self._begins(at)
                self._open(d, True, at)
                self._pos = pos + 2
                continue
            self._after_frame = False
            if c in _OPENERS:
                self._begins(at)
                self._open(c, False, at)
                self._pos = pos + 1
                continue
            if c in _CLOSERS:
                self._close(c, at)
                self._pos = pos + 1
                self._after_frame = True
                continue
            if c == ":":
                self._colon(at)
                self._pos = pos + 1
                continue
            # an atom begins: quoted, or a bare run
            self._begins(at)
            if c == '"' or c == "'":
                self._tok = _Tok(at, c)
                self._tok.parts.append(c)
                self._pos = pos + 1
            else:
                self._tok = _Tok(at, "")

    def _scan_quote(self, tok: _Tok, buf: str, i: int) -> int:
        """Take a quoted atom's text from ``buf[i:]``: the end just past
        its closing quote, or -1 when that hasn't arrived (everything taken
        so far stays in the atom, so the buffer can be dropped). Each escape
        is judged as it is passed, so an unknown one is refused at once
        rather than waiting for a closing quote that can't help."""
        n = len(buf)
        start = i
        q = tok.q
        if tok.escape:
            if i >= n:
                return -1
            if buf[i] not in _ESCAPES and buf[i] != q:
                self._refuse(f"an unknown escape \\{buf[i]}", self._base + i - 1)
            i += 1
            tok.escape = False
        jq = buf.find(q, i)
        while True:
            jb = buf.find("\\", i, jq if jq >= 0 else n)
            if jb < 0:
                if jq < 0:
                    tok.parts.append(buf[start:n])
                    return -1
                tok.parts.append(buf[start:jq])
                return jq + 1
            if jb + 1 >= n:
                tok.parts.append(buf[start:n])
                tok.escape = True
                return -1
            e = buf[jb + 1]
            if e not in _ESCAPES and e != q:
                self._refuse(f"an unknown escape \\{e}", self._base + jb)
            i = jb + 2
            if 0 <= jq < i:
                jq = buf.find(q, i)

    @staticmethod
    def _scan_bare(tok: _Tok, buf: str, i: int) -> int:
        end = _RE_BARE.match(buf, i).end()
        if end > i:
            tok.parts.append(buf[i:end])
        return end if end < len(buf) else -1

    def _atom(self, tok: _Tok) -> Value:
        raw = "".join(tok.parts)
        at = tok.start
        q = tok.q
        if q:
            body, bad = _escape_body(raw[1:], q)
            if body is None:
                self._refuse(f"an unknown escape \\{raw[2 + bad]}", at + 1 + bad)
            try:
                return Text(body) if q == '"' else Symbol(body)
            except NotHeld:
                self._refuse("text that has no UTF-8 form (a lone surrogate)", at)
        c = raw[0]
        if raw.startswith("0x"):
            return self._bytes(raw, at)
        if c in _DIGITS or (c == "-" and len(raw) > 1 and raw[1] in _DIGITS):
            return self._number(raw, at)
        if raw == "nil":
            return Nil()
        try:
            return Symbol(raw)
        except NotHeld:
            self._refuse("a symbol that has no UTF-8 form (a lone surrogate)", at)

    def _bytes(self, tok: str, at: int) -> Value:
        hexes = []
        for i in range(2, len(tok)):
            ch = tok[i]
            if ch == "_":
                if (tok[i - 1] not in _HEX or i + 1 >= len(tok)
                        or tok[i + 1] not in _HEX):
                    self._refuse("'_' sits only between two hex digits", at + i)
            elif ch in _HEX:
                hexes.append(ch)
            else:
                self._refuse(f"{ch!r} is not a hex digit", at + i)
        if len(hexes) % 2:
            self._refuse("bytes need an even count of hex digits", at)
        return Bytes(bytes.fromhex("".join(hexes)))

    def _number(self, tok: str, at: int) -> Value:
        digits = []
        for i, ch in enumerate(tok):
            if ch == "_":
                if (i == 0 or tok[i - 1] not in _DIGITS or i + 1 >= len(tok)
                        or tok[i + 1] not in _DIGITS):
                    self._refuse("'_' sits only between two digits", at + i)
            elif ch in _DIGITS or (ch == "-" and i == 0):
                digits.append(ch)
            else:
                self._refuse("a number ends at a delimiter: there are no "
                             "decimals, and a number can't run into a symbol",
                             at + i)
        spelling = "".join(digits)
        if not _RE_INT.fullmatch(spelling):
            why = ("negative zero" if spelling.startswith("-") and not
                   spelling[1:].strip("0") else "a leading zero")
            self._refuse(f"not an integer's one spelling: {why}", at)
        return Integer(_parse(spelling))

    # -- frames

    def _begins(self, at: int) -> None:
        """A value begins at ``at``. Where no value may stand it is refused
        at once, before the value is whole: text that can't become one value
        is refused however it would have gone on, never left incomplete."""
        if self._stack and self._stack[-1].kind == 0:
            s = self._stack[-1].state
            if s == _Frame.COLON_FIRST:
                self._refuse("'{:' is the empty dict; expected '}'", at)
            if s == _Frame.COLON:
                self._refuse("a dict entry needs ':' after its key", at)

    def _open(self, c: str, marked: bool, at: int) -> None:
        if len(self._stack) >= self.max_depth:
            self._refuse(f"nested past the depth limit ({self.max_depth})", at)
        kind = 6 if c == "[" else 7 if c == "(" else 0
        self._stack.append(_Frame(kind, marked, at))

    def _close(self, c: str, at: int) -> None:
        stack = self._stack
        if not stack:
            self._refuse(f"{c!r} closes nothing", at)
        f = stack[-1]
        want = _CLOSERS[c]
        if f.kind != want:
            expected = "]" if f.kind == 6 else ")" if f.kind == 7 else "}"
            self._refuse(f"{c!r} where {expected!r} closes the frame opened at "
                         f"{self._where_text(f.start)}", at)
        if f.kind == 6:
            v = List._trusted(tuple(f.items), f.mark)
        elif f.kind == 7:
            if not f.items:
                self._refuse("a record with no head", at)
            v = Record._trusted(tuple(f.items), f.mark)
        else:
            s = f.state
            if s == _Frame.KEY:
                v = Dict._trusted({k: f.seen[k] for k in sorted(f.seen, key=_ce_key)},
                                  f.mark)
            elif s == _Frame.COLON_FIRST:
                v = Dict._trusted({}, f.mark)
            elif s in (_Frame.OPEN, _Frame.FIRST, _Frame.SET):
                members = f.items if s != _Frame.FIRST else [f.key]
                v = Set._trusted(sorted(members, key=_ce_key), f.mark)
            elif s == _Frame.COLON:
                self._refuse("a dict entry needs ':' and a value after its key", at)
            else:
                self._refuse("a dict key without a value", at)
        stack.pop()
        self._land(v, f.start, at + 1)

    def _colon(self, at: int) -> None:
        if not self._stack or self._stack[-1].kind != 0:
            self._refuse("':' outside braces", at)
        f = self._stack[-1]
        s = f.state
        if s == _Frame.OPEN:
            f.state = _Frame.COLON_FIRST
        elif s == _Frame.FIRST:
            f.seen = {}
            f.state = _Frame.VALUE
        elif s == _Frame.COLON:
            f.state = _Frame.VALUE
        elif s == _Frame.SET:
            self._refuse("':' in a set; a dict's first entry decides it, "
                         "as {key: value}", at)
        elif s == _Frame.COLON_FIRST:
            self._refuse("'{:' is the empty dict; expected '}'", at)
        else:
            self._refuse("':' where a dict key or value belongs", at)

    def _land(self, v: Value, at: int, end: int) -> None:
        stack = self._stack
        if not stack:
            self._ready.append((v, at, end))
            return
        f = stack[-1]
        if f.kind:
            f.items.append(v)
            return
        s = f.state
        if s == _Frame.OPEN:
            f.key = v
            f.state = _Frame.FIRST
        elif s == _Frame.FIRST:
            if v == f.key:
                self._refuse("a duplicate set member", at)
            f.items = [f.key, v]
            f.seen = dict.fromkeys(f.items)
            f.state = _Frame.SET
        elif s == _Frame.SET:
            if v in f.seen:
                self._refuse("a duplicate set member", at)
            f.seen[v] = None
            f.items.append(v)
        elif s == _Frame.KEY:
            if v in f.seen:
                self._refuse("a duplicate dict key", at)
            f.key = v
            f.state = _Frame.COLON
        elif s == _Frame.VALUE:
            f.seen[f.key] = v
            f.state = _Frame.KEY
        elif s == _Frame.COLON:
            self._refuse("a dict entry needs ':' after its key", at)
        else:  # COLON_FIRST
            self._refuse("'{:' is the empty dict; expected '}'", at)


def read_all(text: str | bytes, *, max_depth: int = DEFAULT_MAX_DEPTH) -> list[Value]:
    """Every value in a document. An empty document is complete."""
    return list(Reader(max_depth=max_depth).feed(text).finish())


def read(text: str | bytes, *, max_depth: int = DEFAULT_MAX_DEPTH) -> Value:
    """Exactly one value, from text that is all there is. Text that stops
    inside the value raises :class:`Incomplete`. Once the value is read,
    anything after it but whitespace and comments begins another, so the
    text can never be one value: it raises :class:`ReadError` however it
    ends, as ``1 [`` and ``go !`` do, and so does text holding no value."""
    r = Reader(max_depth=max_depth)
    r.feed(text).finish()      # fed at once, so r._buf is all the text
    buf = r._buf
    if not r._ready and r._failure is None:
        r._refuse("expected exactly one value, got none", len(buf))
    v, _, end = r._pull()      # or the error that stopped it
    failure = r._failure
    if failure is not None and not isinstance(failure, Incomplete):
        raise failure          # what follows broke a rule, and says which
    rest = _RE_GAP.match(buf, end).end()
    if rest < len(buf) or failure is not None:
        r._refuse("expected exactly one value, and more follows", rest)
    return v


def iter_read(chunks: Iterable[str | bytes], *,
              max_depth: int = DEFAULT_MAX_DEPTH) -> Iterator[Value]:
    """Each value from an iterable of text (or UTF-8 byte) chunks, as soon
    as its text is complete."""
    r = Reader(max_depth=max_depth)
    for chunk in chunks:
        yield from r.feed(chunk)
    yield from r.finish()


def bl(text: str) -> Value:
    """A value from its textual syntax: ``bl('(person {name: "Ada"})')``."""
    if not isinstance(text, str):
        raise TypeError(f"bl() reads text, not {type(text).__name__}; "
                        "for host values use to_value()")
    return read(text)

