"""Levers: searches over values, applied in order between reading and
writing.

A format door's first pass keeps what a document says; a lever rereads
it. Each lever is a search: hand it a value and it answers the readings it
makes of it, usually one (the value with something reread throughout), and
leaves alone what it doesn't apply to. A lever may answer several
readings; whoever consumes them takes them in order.

    from bassline import doors, levers, through

    table = doors.csv.loads(open("people.csv", "rb").read())
    rows = through(levers.header, levers.numbers)(table)   # a stream
    first(rows)        # [{"born": 1815 "name": "Ada"} …]

Levers here (``bl magic -l NAME[=ARG]``, and each also ``bl search NAME``):

=====================  ==================================================
``keys-as-symbols``    every text dict key read as a symbol
``numbers``            every text that spells an integer or a decimal
                       read as one (dict keys stay as they are)
``header[=HEAD]``      a table's first row as its keys: each row a dict,
                       or ``(HEAD {…})`` with a head
``drop-keys=K1,K2``    those keys dropped from every dict
``typed-records=F``    every dict with the key F becomes a record headed
                       by F's value, the rest its field
``entries``            every dict as a list of ``[key value]``
``drop-whitespace``    whitespace-only text beside records dropped from
                       their fields (indentation between XML elements)
=====================  ==================================================

A lever's argument is a value (``header=row``, ``drop-keys=1``,
``drop-keys='"a,b"'``); a bare ``a,b`` is a shorthand for several names.
Keys match a text or symbol key by spelling, any other key by equality.

As Python, each lever is a search function (``levers.numbers``) or makes
one from its argument (``levers.drop_keys("internal", bl("1"))``);
:func:`lever` builds one from its command-line spelling.
"""

from __future__ import annotations

import os
import re
import sys
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from itertools import chain, islice

from .cli import Misuse, Opt, Tool, value_arg
from .edge import ce_writer, read_ce
from .errors import NotHeld
from .ops import _rebuild, fold
from .values import Dict, Kind, List, Record, Symbol, Text, Value, _read, sym
from .doors import _vocab

__all__ = ["LEVERS", "Lever", "lever", "named", "keys_as_symbols", "numbers", "header",
           "drop_keys", "typed_records", "entries", "drop_whitespace", "main"]

Search = Callable[[Value], Iterator[Value]]


def _deep(v: Value, fn: Callable[[Value], Value], *, keys: bool = True) -> Value:
    """``v`` rebuilt bottom up, each value replaced by ``fn(value)`` once
    its members are; with ``keys=False`` dict keys are kept as they were."""
    def step(node: Value, results: tuple) -> Value:
        if node.kind == Kind.DICT and not keys:
            node = Dict(zip(node.keys(), results[1::2]), mark=node.mark)
        else:
            node = _rebuild(node, results)
        return fn(node)
    return fold(v, step)


def _spelled(v: Value) -> str | None:
    return v.value if v.kind in (Kind.TEXT, Kind.SYMBOL) else None


def _matcher(keys: Iterable[Value | str]) -> Callable[[Value], bool]:
    """Whether a dict key is one of ``keys``: a text or symbol key by its
    spelling (a ``str`` is a spelling), any other key by equality."""
    names: set[str] = set()
    others: set[Value] = set()
    for k in keys:
        if isinstance(k, str):
            names.add(k)
        else:
            v = _read(k)
            (names.add(v.value) if v.kind in (Kind.TEXT, Kind.SYMBOL) else others.add(v))
    return lambda k: (k.value in names) if k.kind in (Kind.TEXT, Kind.SYMBOL) else (k in others)


# ---------------------------------------------------------------- levers


def keys_as_symbols(v: Value) -> Iterator[Value]:
    """Every text dict key, at any depth, read as a symbol (keeping its
    mark). A dict where a text key and a symbol key would become one is
    refused."""
    def fn(node: Value) -> Value:
        if node.kind != Kind.DICT or not any(k.kind == Kind.TEXT for k in node):
            return node
        pairs = [(Symbol(k.value, mark=k.mark) if k.kind == Kind.TEXT else k, x)
                 for k, x in node.items()]
        try:
            return Dict(pairs, mark=node.mark)
        except NotHeld:
            names = [k for k, _ in pairs]
            twice = next(k for k in names if names.count(k) > 1)
            raise NotHeld(f"keys-as-symbols: the keys {Text(twice.value)} and {twice} "
                          "would be one key") from None
    yield _deep(v, fn)


def _number(v: Value) -> Value:
    if v.kind != Kind.TEXT:
        return v
    n = _vocab.number(v.value)
    if n is None or n.kind == Kind.RECORD and n.head == _vocab.NUMBER:
        return v
    return n.with_mark(v.mark)


def numbers(v: Value) -> Iterator[Value]:
    """Every text that spells an integer or a decimal, at any depth, read
    as one: ``"1815"`` is ``1815`` and ``"1.50"`` is ``(dec 150 -2)``.
    Only the one spelling of an integer counts (``"007"``, ``"+5"`` and
    ``"-0"`` stay text, so zip codes survive), and a decimal is spelled as
    in JSON (``1.5``, ``1e3``, ``-0.25``). Dict keys stay as they are."""
    yield _deep(v, _number, keys=False)


def header(v: Value, head: Value | str | None = None) -> Iterator[Value]:
    """A table's first row as its keys: each later row a dict from those
    keys to its cells, or a record ``(head {…})`` when ``head`` is given (a
    ``str`` head is a symbol). A row
    shorter than the header leaves the rest of its keys out (it said
    nothing there); cells past the header are keyed by their column
    number, from 0. A header that names a column twice is refused. A value
    that isn't a table (a list of rows, each a list) is answered as it is."""
    if v.kind != Kind.LIST or not len(v) or any(r.kind != Kind.LIST for r in v):
        yield v
        return
    keys = list(v[0])
    seen: set[Value] = set()
    for k in keys:
        if k in seen:
            raise NotHeld(f"header: the column {k} is named twice")
        seen.add(k)
    if head is not None:
        head = sym(head) if isinstance(head, str) else _read(head)
    rows = []
    for row in v[1:]:
        d = Dict(((keys[i] if i < len(keys) else i, c) for i, c in enumerate(row)),
                 mark=row.mark)
        rows.append(Record._trusted((head, d)) if head is not None else d)
    yield List._trusted(tuple(rows), v.mark)


def drop_keys(*keys: Value | str) -> Search:
    """A lever dropping ``keys`` from every dict, at any depth: a text or
    symbol key by its spelling (marked or not; a ``str`` is a spelling),
    any other key by equality."""
    drop = _matcher(keys)

    def fn(node: Value) -> Value:
        if node.kind != Kind.DICT or not any(drop(k) for k in node):
            return node
        return Dict(((k, x) for k, x in node.items() if not drop(k)), mark=node.mark)

    def dropping(v: Value) -> Iterator[Value]:
        yield _deep(v, fn)
    return dropping


def typed_records(field: Value | str) -> Search:
    """A lever turning every dict that has the key ``field`` (a text or
    symbol key by its spelling, any other by equality), at any depth, into
    a record headed by that key's value (text read as a symbol, since a
    head names a topic), with the rest of the dict as its one field:
    ``{"type": "person" "name": "Ada"}`` becomes ``(person {"name": "Ada"})``.
    The dict's mark goes to the record."""
    is_field = _matcher((field,))

    def fn(node: Value) -> Value:
        if node.kind != Kind.DICT:
            return node
        found = [k for k in node if is_field(k)]
        if not found:
            return node
        if len(found) > 1:
            raise NotHeld(f"typed-records: both {found[0]} and {found[1]} are keys")
        h = node[found[0]]
        if h.kind == Kind.TEXT:
            h = Symbol(h.value, mark=h.mark)
        return Record._trusted((h, node.without(found[0])), node.mark)

    def typing(v: Value) -> Iterator[Value]:
        yield _deep(v, fn)
    return typing


def entries(v: Value) -> Iterator[Value]:
    """Every dict, at any depth, as a list of ``[key value]`` lists in the
    dict's order, keeping its mark."""
    def fn(node: Value) -> Value:
        if node.kind != Kind.DICT:
            return node
        return List._trusted(tuple(List._trusted(kv) for kv in node.items()), node.mark)
    yield _deep(v, fn)


_XML_SPACE = re.compile(r"[ \t\r\n]+\Z")


def drop_whitespace(v: Value) -> Iterator[Value]:
    """Fields of records that are only whitespace (space, tab, line
    breaks), dropped where they sit beside records, at any depth: the
    indentation between XML elements. Text that is a record's only content
    (``<b> </b>``, a comment) stays, and lists are left alone, so a table's
    cells keep their columns."""
    def fn(node: Value) -> Value:
        if node.kind != Kind.RECORD or not any(f.kind == Kind.RECORD for f in node.fields):
            return node
        kept = [f for f in node.fields
                if not (f.kind == Kind.TEXT and _XML_SPACE.match(f.value))]
        if len(kept) == len(node.fields):
            return node
        return Record._trusted((node.head, *kept), node.mark)
    yield _deep(v, fn)


# ---------------------------------------------------------------- the catalog


@dataclass(frozen=True)
class Lever:
    """A lever as the command line knows it: its name, what its argument
    is (``None`` when it takes none; in brackets when optional), a line of
    help, and how to make its search from the argument, a value."""

    name: str
    arg: str | None
    summary: str
    make: Callable[[Value | None], Search]

    @property
    def optional(self) -> bool:
        return self.arg is not None and self.arg.startswith("[")

    @property
    def spelling(self) -> str:
        if self.arg is None:
            return self.name
        if self.optional:
            return f"{self.name}[={self.arg[1:-1]}]"
        return f"{self.name}={self.arg}"


def _keys_of(arg: Value) -> list[Value | str]:
    """The keys an argument names: the members of a list or set, the names
    in a bare ``a,b`` (a symbol with commas, as a shell argument spells
    several names), or the value itself."""
    if arg.kind in (Kind.LIST, Kind.SET):
        return list(arg)
    if arg.kind == Kind.SYMBOL and "," in arg.name and not arg.mark:
        return [n for n in arg.name.split(",") if n]
    return [arg]


def _header_lever(arg: Value | None) -> Search:
    if arg is None:
        return header
    return lambda v: header(v, arg)


LEVERS: tuple[Lever, ...] = (
    Lever("keys-as-symbols", None, "every text dict key read as a symbol",
          lambda arg: keys_as_symbols),
    Lever("numbers", None, "every text that spells an integer or a decimal read as one "
          "(not dict keys)", lambda arg: numbers),
    Lever("header", "[HEAD]", "a table's first row as its keys: each row a dict, or "
          "(HEAD {...}) with a head", _header_lever),
    Lever("drop-keys", "K1,K2", "those keys (text or symbol) dropped from every dict",
          lambda arg: drop_keys(*_keys_of(arg))),
    Lever("typed-records", "FIELD", "every dict with the key FIELD becomes a record "
          "headed by its value", lambda arg: typed_records(arg)),
    Lever("entries", None, "every dict as a list of [key value]", lambda arg: entries),
    Lever("drop-whitespace", None, "whitespace-only text beside records dropped "
          "(indentation between XML elements)", lambda arg: drop_whitespace),
)


def named(name: str, among: Iterable[Lever] = LEVERS) -> Lever | None:
    """The lever called ``name`` here, or ``None``."""
    return next((lv for lv in among if lv.name == name), None)


def lever(spec: str, among: Iterable[Lever] = LEVERS) -> Search:
    """The search a lever's command-line spelling names: ``"numbers"``,
    ``"drop-keys=internal,debug"``, ``'header=row'``. The argument is a
    value, read as the textual syntax (or CE). ``LookupError`` for a name
    no lever here has, ``ValueError`` for a wrong argument."""
    name, eq, arg = spec.partition("=")
    lv = named(name, among)
    if lv is None:
        raise LookupError(name)
    if lv.arg is None and eq:
        raise ValueError(f"the lever {name} takes no argument")
    if lv.arg is not None and not lv.optional and not arg:
        raise ValueError(f"the lever {name} needs an argument: {lv.spelling}")
    if not arg:
        return lv.make(None)
    try:
        return lv.make(value_arg(arg, files=False))
    except Misuse as e:
        raise ValueError(f"the lever {name}'s argument: {e}") from None


# ---------------------------------------------------------------- bl search NAME


def _tool(lv: Lever) -> Tool:
    def run(tool: Tool, opts: dict, args: list[str]) -> int:
        if lv.arg is None and args:
            raise Misuse(f"takes no query, got {len(args)}")
        if lv.arg is not None and not lv.optional and len(args) != 1:
            raise Misuse(f"takes one query, {lv.arg}; got {len(args)}")
        if len(args) > 1:
            raise Misuse(f"takes at most one query, got {len(args)}")
        take = opts.get("take")
        if take is not None:
            if not take.isdigit():
                raise Misuse(f"-n takes a count, not {take!r}")
            take = int(take)
        search = lv.make(value_arg(args[0]) if args else None)
        answers = chain.from_iterable(map(search, read_ce(0)))
        if take is not None:
            answers = islice(answers, take)
        out = ce_writer(1)
        for a in answers:
            if out(a) is False:
                break
        return 0

    return Tool(
        name=f"bl search {lv.name}",
        synopsis=(f"{lv.arg} " if lv.arg else "") + "[-n N]",
        summary=lv.summary,
        run=run,
        opts=(Opt("take", "n", "N", "take N answers, then stop"),),
        about=("Asks about each value on stdin in turn. Reads CE on stdin and\n"
               "writes each answer as CE as soon as it has it, so it keeps up\n"
               "with a live pipe. "
               + ("The query is the lever's argument, a value\nread by recognition (a "
                  "file, else the textual syntax, else CE),\n"
                  f"as in `bl magic -l {lv.spelling}`." if lv.arg else
                  f"The same as `bl magic -l {lv.name}`.")))


def main(name: str | None = None, argv: list[str] | None = None) -> int:
    """``bl-search-NAME``: the lever NAME as a filter over CE. With no
    ``name``, it is taken from the program's own name."""
    if name is None:
        prog = os.path.basename(sys.argv[0])
        name = prog[len("bl-search-"):] if prog.startswith("bl-search-") else prog
    for lv in LEVERS:
        if lv.name == name:
            return _tool(lv).main(argv)
    sys.stderr.write(f"no lever {name}\n")
    return 2


def _entry(name: str) -> Callable[[], int]:
    def entry() -> int:
        return main(name)
    entry.__name__ = "main_" + name.replace("-", "_")
    return entry


# console-script entry points, one per lever: bl-search-NAME = bassline.levers:main_NAME
main_keys_as_symbols = _entry("keys-as-symbols")
main_numbers = _entry("numbers")
main_header = _entry("header")
main_drop_keys = _entry("drop-keys")
main_typed_records = _entry("typed-records")
main_entries = _entry("entries")
main_drop_whitespace = _entry("drop-whitespace")

if __name__ == "__main__":
    sys.exit(main())
