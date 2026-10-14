"""Format doors: foreign documents in, values out, and back.

Each door is a module with a ``door`` object and the same few functions:

    from bassline import doors

    doors.json.loads('{"price": 1.50}')      # {"price": (dec 150 -2)}
    doors.json.read(data)                    # a stream of the document's values
    doors.json.read(data, "json-entries")    # another of the door's readings
    doors.toml.dumps(value)                  # one value, written
    send = doors.csv.writer(file)            # a send writing each value it gets
    doors.xml.sure(data)                     # 0-100: how sure, for guessing

The first pass of every door keeps everything the document says, in
arrangements that hold it exactly, and refuses (``NotHeld``) only what
values can't hold. Writing out is lossy. :mod:`bassline.levers` refines
what a first pass reads.

Doors here: ``ce``, ``text``, ``json``, ``carrier``, ``csv``, ``tsv``,
``toml``, ``xml``, and ``yaml`` when PyYAML is installed. :data:`ALL` is
the doors that work on this host, :data:`KNOWN` every door including any
that is missing what it needs.
"""

from __future__ import annotations

import os
from collections.abc import Iterable, Iterator

from ..errors import BasslineError
from ..values import Value, rec, sym
from . import carrier, ce, csv, json, text, toml, tsv, xml, yaml
from ._door import Door

__all__ = ["Door", "ALL", "KNOWN", "PLAUSIBLE", "named", "by_extension", "guess",
           "readings", "ce", "text", "json", "carrier", "csv", "tsv", "toml", "xml", "yaml"]

#: Every door this package has, in the order a tie in sureness goes.
KNOWN: tuple[Door, ...] = (ce.door, carrier.door, json.door, toml.door, xml.door,
                           yaml.door, tsv.door, csv.door, text.door)

#: The doors that work here.
ALL: tuple[Door, ...] = tuple(d for d in KNOWN if d.available)

#: Below this sureness a door's reading isn't counted as plausible.
PLAUSIBLE = 20

READING = sym.reading


def named(name: str, among: Iterable[Door] = KNOWN) -> Door:
    """The door with a reading or writer called ``name`` (``json-entries``
    is the json door's). ``LookupError`` if none has."""
    for d in among:
        if name == d.name or name in d.readings or name in d.writers:
            return d
    raise LookupError(name)


def by_extension(path: str, among: Iterable[Door] = KNOWN) -> Door | None:
    """The door whose extension ``path`` ends with, the longest match
    winning (``.carrier.json`` before ``.json``), or ``None``."""
    base = os.path.basename(path).lower()
    best, length = None, 0
    for d in among:
        for ext in d.extensions:
            if base.endswith(ext) and len(ext) > length and len(base) > len(ext):
                best, length = d, len(ext)
    return best


def guess(data: bytes | str, among: Iterable[Door] = ALL) -> list[tuple[int, Door]]:
    """Every door that is at all sure ``data`` is its format, the surest
    first: ``[(sureness, door), …]``."""
    ranked = [(d.sure(data), i, d) for i, d in enumerate(among)]
    ranked.sort(key=lambda t: (-t[0], t[1]))
    return [(s, d) for s, _, d in ranked if s > 0]


def readings(data: bytes | str, among: Iterable[Door] = ALL, *,
             prefer: Door | None = None, at_least: int = PLAUSIBLE) -> Iterator[Value]:
    """Every plausible reading of a document, as ``(reading FMT value)``,
    one for each value a reading holds.

    This search works when it is asked: it asks every door how sure it is
    and ranks them then, before any answer is pulled. The stream it hands
    back reads the document by one door's reading at a time, surest first
    (``prefer`` first of all, when given), and answers the values of each
    reading that holds; readings the document breaks are passed over. With
    ``at_least=0`` every door given is tried, however unsure."""
    sized = sorted(((d.sure(data), i, d) for i, d in enumerate(among)),
                   key=lambda t: (-t[0], t[1]))
    ranked = [d for s, _, d in sized if (s >= at_least and s > 0) or at_least <= 0 or d is prefer]
    if prefer is not None and prefer in ranked:
        ranked.remove(prefer)
        ranked.insert(0, prefer)
    return _read_each(data, ranked)


def _read_each(data, ranked: list[Door]) -> Iterator[Value]:
    for d in ranked:
        for name in d.readings:
            try:
                values = list(d.read(data, name))
            except (BasslineError, TypeError):
                continue
            label = sym(name)
            for v in values:
                yield rec(READING, label, v)
