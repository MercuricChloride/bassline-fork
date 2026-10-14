"""Searches and streams.

A *search* is what you ask: a callable that takes a query (a value, or
anything else) and hands back a stream. A *stream* is what it hands back:
a Python iterator, pulled one answer at a time with ``next`` or a ``for``
loop. You call a search; you pull a stream.

    def steps(term):                  # a search
        while (term := reduce_once(term)) is not None:
            yield term                # one answer per pull

    stream = steps(t)                 # asking: nothing has run yet
    first(stream)                     # pulling one answer

A generator function is the laziest search: its body runs only as answers
are pulled. A search can as easily do its work the moment it is asked and
hand back a stream over what it found; :func:`bassline.doors.readings`
sizes up every format door when asked, then reads the document one door at
a time, as its answers are pulled.

Pulls decide how much you take, not how much a search does. Either side
may stop: the stream may have nothing more to give, or the consumer may
take no more. Neither is finality. Once a stream has nothing more, asking
again starts a new one, which may answer differently.

Combining streams, with Python's own tools where they already fit:

==================  ======================================================
``alt(*streams)``   fair turns, so an endless stream can't starve the rest
``alt_from(ss)``    fair turns over a stream of streams, admitting each
                    newcomer on its turn
``feed(s, search)`` each answer asked of ``search``, its streams alternated
``first(s)``        the first answer, or ``None`` if there is none
``take(s, n)``      up to ``n`` answers, pulling no more than that
cat                 ``itertools.chain``; ``chain.from_iterable`` for a
                    stream of streams, one after another
map, filter         the builtins, or a generator expression
==================  ======================================================

Combining searches: :func:`fan` asks several searches the same thing and
alternates their streams; :func:`through` feeds each answer of one search
to the next. Both are searches themselves.
"""

from __future__ import annotations

import threading
from collections import deque
from collections.abc import Callable, Iterable, Iterator
from itertools import islice
from typing import Any, TypeVar

from .ops import under
from .values import Value, _read

__all__ = ["alt", "alt_from", "feed", "first", "take", "fan", "through", "Heard"]

A = TypeVar("A")
Q = TypeVar("Q")
Search = Callable[[Any], Iterator[A]]

_NOTHING = object()


def alt(*streams: Iterable[A]) -> Iterator[A]:
    """Answers taken in turn, one from each stream (the first, the second,
    ..., the first again), dropping each stream once it has nothing more,
    until none has. An endless stream can't starve the others."""
    live = deque(map(iter, streams))
    while live:
        s = live.popleft()
        a = next(s, _NOTHING)
        if a is not _NOTHING:
            live.append(s)
            yield a


def alt_from(streams: Iterable[Iterable[A]]) -> Iterator[A]:
    """Fair turns over a stream of streams. ``streams`` is pulled lazily:
    it takes one turn in each round, beside the streams it has already
    given, and the newcomer it gives answers in that same round. So a
    stream learned a moment ago joins the rotation, and an endless supply
    of streams doesn't hold up the answers of the first ones.

    Each round: one newcomer from ``streams`` (while it has any), then one
    answer from each live stream in turn, dropping those that have nothing
    more."""
    source = iter(streams)
    live: deque[Iterator[A]] = deque()
    more = True
    while more or live:
        if more:
            s = next(source, _NOTHING)
            if s is _NOTHING:
                more = False
            else:
                live.append(iter(s))
        for _ in range(len(live)):
            s = live.popleft()
            a = next(s, _NOTHING)
            if a is not _NOTHING:
                live.append(s)
                yield a


def feed(stream: Iterable[Any], search: Search) -> Iterator[A]:
    """Each answer of ``stream`` handed to ``search``, and the streams that
    come back alternated fairly: ``alt_from(map(search, stream))``. A
    search that answers endlessly about one value doesn't hold back the
    answers about the next.

    To drain each value's answers before pulling the next value instead
    (what an edge filter does, so a live pipe isn't held waiting for the
    next arrival), it's ``chain.from_iterable(map(search, stream))``."""
    return alt_from(map(search, stream))


def first(stream: Iterable[A], default: Any = None) -> A | Any:
    """The first answer, pulling only that; ``default`` (``None``) if the
    stream has nothing. Pass a ``default`` of your own to tell a ``None``
    answer from no answer."""
    return next(iter(stream), default)


def take(stream: Iterable[A], n: int) -> list[A]:
    """Up to ``n`` answers, as a list, pulling no more than that.
    ``itertools.islice(stream, n)`` takes them lazily instead."""
    return list(islice(stream, n))


def fan(*searches: Search) -> Search:
    """A search that asks every one of ``searches`` the same query and
    alternates their streams fairly."""
    def fanned(query):
        return alt(*(s(query) for s in searches))
    return fanned


def through(*searches: Search) -> Search:
    """A search that asks the first of ``searches``, hands each answer to
    the next, and so on; the last one's answers are the stream. Answers
    that branch (a search answering several) are alternated fairly, as in
    :func:`feed`. With no searches, it answers the query itself."""
    def threaded(query):
        stream: Iterator = iter((query,))
        for s in searches:
            stream = feed(stream, s)
        return stream
    return threaded


class Heard:
    """What has been heard, kept in the order it arrived, each value once.

    ``add`` is a send: hand it a value and it keeps it, answering ``True``.
    Iterating, and :meth:`under`, are searches over what has been heard as
    of each pull: a value that arrives while a stream is being pulled is
    answered too, so a stream over ``Heard`` fed by an edge tool on another
    thread keeps up with what lands. Nothing is ever taken back; dropping a
    ``Heard`` is a local decision.

        heard = Heard()
        signer = pipe(["blclave"], into=heard.add)
        to_signer = signer.send
        ...
        for s in heard.under(rec(sym.signed, v)):
            ...
    """

    __slots__ = ("_order", "_seen", "_lock")

    def __init__(self, values: Iterable[Any] = ()):
        self._order: list[Value] = []
        self._seen: set[Value] = set()
        self._lock = threading.Lock()
        for v in values:
            self.add(v)

    def add(self, value: Any) -> bool:
        """Keep ``value`` (read with the default reading); a send."""
        v = _read(value)
        with self._lock:
            if v not in self._seen:
                self._seen.add(v)
                self._order.append(v)
        return True

    __call__ = add

    def __contains__(self, value: Any) -> bool:
        return _read(value) in self._seen

    def __len__(self) -> int:
        return len(self._order)

    def __iter__(self) -> Iterator[Value]:
        order = self._order
        i = 0
        while i < len(order):
            yield order[i]
            i += 1

    def under(self, prefix: Any) -> Iterator[Value]:
        """Every value heard that ``prefix`` prefixes (see
        :func:`bassline.prefixes`), as of each pull. A prefix narrows;
        equality or a shape decides."""
        return under(_read(prefix), self)

    def __repr__(self) -> str:
        return f"<Heard {len(self._order)} value(s)>"
