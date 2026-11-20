"""Why something was refused, or why it is still waiting.

Two different things, kept apart::

    BasslineError (a ValueError)
    ├── Refused          what arrived breaks a rule
    │   ├── DecodeError  bytes, with a Reason
    │   ├── ReadError    text
    │   └── NotHeld      a reading can't hold it (also a TypeError)
    └── Incomplete       what arrived could still begin something valid

``except Refused`` catches only refusals; :class:`Incomplete` is a note that
more input would be needed, never a judgement of what came.
"""

from __future__ import annotations

import enum

__all__ = [
    "BasslineError",
    "Refused",
    "Reason",
    "DecodeError",
    "ReadError",
    "Incomplete",
    "NotHeld",
]


class BasslineError(ValueError):
    """Base of what this package raises about its input: a refusal, or
    input that stopped too early."""


class Refused(BasslineError):
    """What arrived breaks a rule, and no more input could mend it."""


class Reason(enum.StrEnum):
    """Why a decoder refused bytes.

    The first eleven are the corpus's names, exactly. The rest are this
    implementation's own, since the corpus names no reason for them.
    """

    INVALID_TAG = "invalid-tag"
    END_WITH_BITS = "end-with-bits"
    END_AT_TOP = "end-at-top"
    LENGTH_BITS = "length-bits"
    NON_MINIMAL_LENGTH = "non-minimal-length"
    BAD_INTEGER = "bad-integer"
    BAD_UTF8 = "bad-utf8"
    EMPTY_RECORD = "empty-record"
    STRANDED_KEY = "stranded-key"
    OUT_OF_ORDER = "out-of-order"
    DUPLICATE = "duplicate"
    #: A frame opened past the decoder's depth limit.
    TOO_DEEP = "too-deep"
    #: A value whose bytes would pass the decoder's cap on bytes buffered
    #: toward one value.
    TOO_LARGE = "too-large"
    #: One-shot :func:`bassline.decode` only: one value was asked for, and
    #: whole values followed it.
    TRAILING_BYTES = "trailing-bytes"


class DecodeError(Refused):
    """Bytes refused. ``reason`` names the rule, ``offset`` is the input
    offset of the first byte that broke it."""

    def __init__(self, reason: Reason, offset: int):
        self.reason = Reason(reason)
        self.offset = offset
        super().__init__(f"{self.reason} at byte {offset}")

    def __reduce__(self):
        return (type(self), (self.reason, self.offset))


class ReadError(Refused):
    """Text refused. ``offset`` counts characters (code points) from the
    start of the input; ``line`` and ``column`` are 1-based."""

    def __init__(self, message: str, offset: int, line: int, column: int):
        self.message = message
        self.offset = offset
        self.line = line
        self.column = column
        super().__init__(f"line {line}, column {column}: {message}")

    def __reduce__(self):
        return (type(self), (self.message, self.offset, self.line, self.column))


class Incomplete(BasslineError):
    """The input stopped partway through a value: what arrived could still
    begin something valid. ``offset`` is where the input ended (bytes for
    the decoder, characters for the reader); ``line`` and ``column`` are
    set for text."""

    def __init__(self, message: str, offset: int, line: int | None = None,
                 column: int | None = None):
        self.message = message
        self.offset = offset
        self.line = line
        self.column = column
        where = (f"line {line}, column {column}" if line is not None
                 else f"byte {offset}")
        super().__init__(f"{where}: {message}")

    def __reduce__(self):
        return (type(self), (self.message, self.offset, self.line, self.column))


class NotHeld(Refused, TypeError):
    """A reading refused what it was handed rather than coerce it: a bool
    or float offered as a value, a lone surrogate offered as text, a value
    a host type cannot hold."""
