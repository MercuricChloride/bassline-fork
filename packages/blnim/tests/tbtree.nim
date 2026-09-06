## core/btree: low / high — the smallest and largest key, found by
## descending the leftmost / rightmost spine of the node tree.

import std/[algorithm, random, sequtils, unittest]
import bl/core

suite "low / high":

  test "an empty tree has neither":
    var t = newBTree[int, bool]()
    expect KeyError: discard t.low
    expect KeyError: discard t.high
    # a tree that was never given a root at all
    var raw: BTree[int, bool]
    expect KeyError: discard raw.low
    expect KeyError: discard raw.high

  test "one element is both bounds":
    var t = newBTree[int, bool]()
    t.incl 42
    check t.low == 42
    check t.high == 42

  test "bounds over a tree deep enough to have split":
    var rng = initRand(20)
    var t = newBTree[int, bool]()
    var xs: seq[int]
    for _ in 0 ..< 5000:
      let x = rng.rand(-1_000_000 .. 1_000_000)
      if x notin xs:            # the set drops dupes; keep the reference in step
        xs.add x
      t.incl x
    xs.sort()
    check t.len == xs.len
    check toSeq(t.keys) == xs           # sanity: full order
    check t.low == xs[0]
    check t.high == xs[^1]

  test "bounds move as smaller / larger keys arrive":
    var t = newBTree[int, bool]()
    for x in [10, 20, 30]: t.incl x
    check t.low == 10
    check t.high == 30
    t.incl 5
    t.incl 99
    check t.low == 5
    check t.high == 99
    t.incl 50                            # interior key, no bound change
    check t.low == 5
    check t.high == 99

  test "on a key/value tree, t[t.high] is the largest key's value":
    var t = newBTree[int, string]()
    for i in 1 .. 200: t[i] = "v" & $i
    check t.low == 1
    check t.high == 200
    check t[t.low] == "v1"
    check t[t.high] == "v200"

  test "matches a Value-keyed set (btree behind dicts / sets)":
    var s = initSet()
    s.els.incl sym"m"
    s.els.incl num(3)
    s.els.incl text"z"
    s.els.incl null()
    # canonical order: nil, number, text, symbol
    check s.els.low == null()
    check s.els.high == sym"m"
