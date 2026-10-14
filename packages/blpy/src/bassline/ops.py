"""Working with values without knowing what they mean: walking, folding,
rebuilding, and prefixes.

Everything here uses an explicit stack, so a value's depth never reaches
the call stack.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Iterator
from itertools import chain
from typing import Any, TypeVar

from .values import Dict, List, Record, Set, Value, _read

__all__ = ["walk", "fold", "transform", "prefixes", "frame_key", "under"]

T = TypeVar("T")
_DONE = object()


def _constituents(v: Value) -> Iterator[Value]:
    """A frame's members in encoding order: a dict's go key, value, key,
    value; an atom has none."""
    k = v.kind
    if k == 6 or k == 7:
        return iter(v._m)
    if k == 9:
        return iter(v._d)
    if k == 8:
        return chain.from_iterable(v._d.items())
    return iter(())


def walk(v: Value) -> Iterator[Value]:
    """Every value in ``v``, ``v`` first, depth first, members in encoding
    order (a dict key just before its value)."""
    stack = [iter((v,))]
    while stack:
        x = next(stack[-1], _DONE)
        if x is _DONE:
            stack.pop()
            continue
        yield x
        if x.kind >= 6:
            stack.append(_constituents(x))


def fold(v: Value, fn: Callable[[Value, tuple], T]) -> T:
    """Fold ``v`` bottom up: ``fn(value, results)``, where ``results`` are
    the folds of its constituents in encoding order (empty for an atom; a
    dict's alternate key, value). The canonical encoding is such a fold::

        fold(v, lambda x, rs: x.ce if x.is_atom else
             bytes([x.ce[0]]) + b"".join(rs) + b"\\xa0")
    """
    if v.kind < 6:
        return fn(v, ())
    stack: list[tuple[Value, Iterator[Value], list]] = [(v, _constituents(v), [])]
    while True:
        node, it, results = stack[-1]
        child = next(it, _DONE)
        if child is _DONE:
            stack.pop()
            r = fn(node, tuple(results))
            if not stack:
                return r
            stack[-1][2].append(r)
        elif child.kind < 6:
            results.append(fn(child, ()))
        else:
            stack.append((child, _constituents(child), []))


def _rebuild(node: Value, members: tuple) -> Value:
    k = node.kind
    if k < 6:
        return node
    old = tuple(_constituents(node))
    if len(old) == len(members) and all(a is b for a, b in zip(old, members)):
        return node
    mark = node.mark
    if k == 6:
        return List._trusted(members, mark)
    if k == 7:
        return Record._trusted(members, mark)
    if k == 9:
        return Set(members, mark=mark)
    return Dict(zip(members[::2], members[1::2]), mark=mark)


def transform(v: Value, fn: Callable[[Value], Any]) -> Value:
    """Rebuild ``v`` bottom up: each value, its members already
    transformed, is replaced by ``fn(value)`` (a host result is read with
    the default reading). Marks stay where they are unless ``fn`` changes
    them. Set members or dict keys that become equal are one member (and a
    dict refuses keys that collide)."""
    return fold(v, lambda node, rs: _read(fn(_rebuild(node, rs))))


def prefixes(a: Value, b: Value) -> bool:
    """Whether ``a`` is a prefix of ``b``: what ``b``'s canonical encoding
    yields when stopped early, every frame the stop left open closed by
    END. Reflexive; kind and mark must agree. Among scalars only equal
    values are prefixes, since a scalar carries its own length. In a frame
    every member but the last must equal ``b``'s and the last is itself a
    prefix of ``b``'s. Dicts and sets compare in canonical order, so a
    prefix is a leading run of the sorted members, not a subset."""
    while True:
        k = a.kind
        if k != b.kind or a.mark != b.mark:
            return False
        if k < 6:
            return a == b
        if k == 8:
            ea, eb = list(a._d.items()), list(b._d.items())
            n = len(ea)
            if n > len(eb):
                return False
            if n == 0:
                return True
            for i in range(n - 1):
                if ea[i][0] != eb[i][0] or ea[i][1] != eb[i][1]:
                    return False
            if ea[-1][0] != eb[n - 1][0]:
                return False
            a, b = ea[-1][1], eb[n - 1][1]
            continue
        ma = a._m if k != 9 else tuple(a._d)
        mb = b._m if k != 9 else tuple(b._d)
        n = len(ma)
        if n > len(mb):
            return False
        if n == 0:
            return True
        for i in range(n - 1):
            if ma[i] != mb[i]:
                return False
        a, b = ma[-1], mb[n - 1]


def frame_key(q: Value) -> bytes:
    """The byte prefix that selects exactly the values ``q`` prefixes (see
    :func:`prefixes`): ``q``'s encoding without the END of each frame along
    its last-member spine. A scalar's key is its whole encoding. A prefix
    narrows; equality or a shape decides, since ``(signed [1 2])`` also
    prefixes ``(signed [1 2 3] …)``."""
    opens = 0
    v = q
    while v.kind >= 6:
        opens += 1
        k = v.kind
        if k == 8:
            if not v._d:
                break
            v = next(reversed(v._d.values()))
        else:
            ms = v._m if k != 9 else v._d
            if not ms:
                break
            v = next(reversed(ms)) if k == 9 else ms[-1]
    ce = q.ce
    return ce[:len(ce) - opens]


def under(q: Value, values: Iterable[Value]) -> Iterator[Value]:
    """The values in ``values`` that ``q`` prefixes, picked by
    :func:`frame_key` on their bytes."""
    key = frame_key(q)
    return (v for v in values if v.ce.startswith(key))
