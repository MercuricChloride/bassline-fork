"""The shared corpus, three ways: ``corpus.bl`` through the reader,
``corpus.blb`` through the decoder, ``corpus.json`` through the carrier."""

from __future__ import annotations

import os
import random

import _path  # noqa: F401
from bassline import carrier, decode_all, read_all, sym

DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "..", "..", "corpus"))
HEADS = ("ce", "reject", "starved", "reads", "refuses", "incomplete", "document")


def raw(name: str) -> bytes:
    with open(os.path.join(DIR, name), "rb") as f:
        return f.read()


def from_bl():
    return read_all(raw("corpus.bl").decode("utf-8"))


def from_blb():
    return decode_all(raw("corpus.blb"))


def shuffle_members(tree, rng: random.Random) -> int:
    """Shuffle every dict's entries and every set's members in a carrier
    tree, in place, so the reading has to sort them. Returns how many
    collections of two or more were shuffled."""
    count = 0
    stack = [tree]
    while stack:
        node = stack.pop()
        if isinstance(node, list):
            stack.extend(node)
        elif isinstance(node, dict):
            value = node.get("value")
            if node.get("kind") in ("dict", "set") and len(value) > 1:
                original = list(value)
                while value == original:
                    rng.shuffle(value)
                count += 1
            if isinstance(value, list):
                stack.extend(value)
    return count


def from_json(seed: int | None = None):
    tree = carrier.load_tree(raw("corpus.json"))
    if seed is not None:
        shuffle_members(tree, random.Random(seed))
    return [carrier.from_carrier(case) for case in tree]


cases = from_bl()


def of(head: str):
    """The cases under one head."""
    h = sym(head)
    return [c for c in cases if c.head == h]
