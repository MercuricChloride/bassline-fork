"""Bassline values in Python.

Values are atoms (nil, integer, text, symbol, bytes) or frames (list,
record, dict, set), and any value may carry a mark. Identity is the
canonical encoding: values are equal, hash and sort by their CE bytes.

    >>> from bassline import bl, sym, rec, encode, decode
    >>> v = bl('(person {name: "Ada" born: 1815})')
    >>> v == rec(sym.person, {sym.name: "Ada", sym.born: 1815})
    True
    >>> decode(encode(v)) == v
    True
    >>> print(v)
    (person {born: 1815 name: "Ada"})
"""

from __future__ import annotations

from . import carrier, doors, levers
from .codec import (
    DEFAULT_MAX_DEPTH,
    DEFAULT_MAX_VALUE_BYTES,
    Decoder,
    decode,
    decode_all,
    encode,
    encode_all,
    iterdecode,
)
from .edge import Pipe, ce_writer, chunks, pipe, read_ce
from .errors import BasslineError, DecodeError, Incomplete, NotHeld, ReadError, Reason, Refused
from .ops import fold, frame_key, prefixes, transform, under, walk
from .readings import (
    Reading,
    ReadingOut,
    plain,
    symbol_keys,
    symbolic,
    to_python,
    to_value,
)
from .search import Heard, alt, alt_from, fan, feed, first, take, through
from .text import Reader, bl, iter_read, pretty, read, read_all, to_text
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
    mark,
    nil,
    rec,
    sym,
    unmark,
)

__version__ = "0.1.0"

__all__ = [
    # values
    "Kind", "Value", "Nil", "Integer", "Text", "Symbol", "Bytes",
    "List", "Record", "Dict", "Set", "nil", "sym", "rec", "mark", "unmark",
    # readings
    "Reading", "ReadingOut", "to_value", "symbolic", "symbol_keys",
    "to_python", "plain",
    # canonical encoding
    "encode", "encode_all", "decode", "decode_all", "Decoder", "iterdecode",
    "DEFAULT_MAX_DEPTH", "DEFAULT_MAX_VALUE_BYTES",
    # text
    "bl", "read", "read_all", "Reader", "iter_read", "to_text", "pretty",
    # working with values
    "walk", "fold", "transform", "prefixes", "frame_key", "under",
    # searches and streams
    "alt", "alt_from", "feed", "first", "take", "fan", "through", "Heard",
    # the edge
    "chunks", "read_ce", "ce_writer", "pipe", "Pipe",
    # the JSON carrier, format doors and levers
    "carrier", "doors", "levers",
    # refusals
    "BasslineError", "Refused", "DecodeError", "ReadError", "NotHeld", "Incomplete", "Reason",
]
