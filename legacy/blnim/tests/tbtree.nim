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
    t[42] = true
    check t.low == 42
    check t.high == 42

  test "bounds over a tree deep enough to have split":
    var t = newBTreeSet[int]()
    var xs: seq[int]
    for _ in 0 ..< 5000:
      let x = rand(-1_000_000 .. 1_000_000)
      if x notin xs: # the set drops dupes; keep the reference in step
        xs.add x
      t.incl x
    xs.sort()
    check t.len == xs.len
    check toSeq(t) == xs           # sanity: full order
    check t.low == xs[0]
    check t.high == xs[^1]

  test "bounds move as smaller / larger keys arrive":
    var t = newBTreeSet[int]()
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

func sum(acc, curr: int): int =
  acc + curr
func sum(acc, k, v: int): int =
  acc + k + v

suite "set ops":
  let
    a = newBTreeSet[int]()
    b = newBTreeSet[int]()

  for i in 1..6:
    a.incl i
  for i in 4..10:
    b.incl i
  
  test "union":
    let c = a + b
    for i in 1..10:
      check i in c
  
  test "difference":
    let c = a - b
    for i in 1..3:
      check i in c

  test "intersection":
    let c = a * b
    for i in 4..6:
      check i in c

  test "symmetric difference":
    let c = symmetricDifference(a, b)
    for i in 1..10:
      check (i in c) == (i notin 4..6)

  test "mapping":
    let 
      c = a + b
      d = c.map(func(x: int): auto = x * 2)
    for x in c:
      check x*2 in d

  test "filtering":
    let
      c = a + b
      d = c.filter(func(x: int): auto = x mod 2 == 0)
    check d < c

  test "reducing":
    let
      c = a + b
      d = c.reduce(0, func(x, y: int): int = x + y)
    check d == 55

suite "dict ops":

  let
    a = newBTree[int, int]()
    b = newBTree[int, int]()

  for i in 1..6:
    a[i] = i * 2
  for i in 4..10:
    b[i] = i * 2

  test "union":
    let c = a + b
    for i in 1..10:
      check i in c
      check c[i] == i*2
  
  test "difference":
    let c = a - b
    for i in 1..3:
      check i in c
      check c[i] == i*2

  test "intersection":
    let c = a * b
    for i in 4..6:
      check i in c
      check c[i] == i*2

  test "mapping":
    proc fn(k, v: int): auto =
      (k, v * 2)
    let
      c = a + b
      d = map(c, fn)
    for k,v in c:
      check k in d
      check d[k] == c[k] * 2

  test "filtering":
    let
      c = a + b
      d = c.filter(
        proc(k, _: int): auto = k mod 2 == 0
      )
        
    for k,v in c:
      if k mod 2 == 0:
        check k in d
      else:
        check k notin d

  test "reducing":
    let
      c = a + b
      d = c.reduce(0, sum)
    check d == 165
  
  test "dict -> set":
    let 
      keys = a.keys
      vals = a.values
      all = keys + vals
    for e in keys:
      echo "key: ", e
    for e in vals:
      echo "val: ", e
    echo "sum: ", all.reduce(0, sum)
suite "bounded by a predicate":
  # a bound that needn't be a member: evens from 0 to 2000, asked from 501
  let evens = newBTreeSet[int]()
  for i in 0 .. 1000: evens.incl 2 * i
  proc atLeast(n: int): proc(x: int): bool = (proc(x: int): bool = x >= n)
  proc atMost(n: int): proc(x: int): bool = (proc(x: int): bool = x <= n)

  test "from the first member the bound holds for, onward":
    var got: seq[int]
    for x in evens.itemsFrom(atLeast(501)): got.add x
    check got.len == 750
    check got[0] == 502 and got[^1] == 2000

  test "between two bounds":
    var got: seq[int]
    for x in evens.itemsFrom(atLeast(501), atMost(521)): got.add x
    check got == @[502, 504, 506, 508, 510, 512, 514, 516, 518, 520]

  test "a bound past every member, or before the first":
    var n = 0
    for x in evens.itemsFrom(atLeast(2001)): inc n
    check n == 0
    for x in evens.itemsFrom(atLeast(-5), atMost(2)): inc n
    check n == 2
    for x in newBTreeSet[int]().itemsFrom(atLeast(0)): inc n
    check n == 2

  test "dict entries the same way":
    let d = newBTree[int, string]()
    for i in 0 .. 300: d[3 * i] = $i
    var got: seq[string]
    for k, v in d.pairsFrom(atLeast(100), atMost(110)): got.add v
    check got == @["34", "35", "36"]

  test "the descent bisects instead of walking from the first member":
    var asked = 0
    proc counting(x: int): bool =
      inc asked
      x >= 1900
    for x in evens.itemsFrom(counting): discard
    check asked < 120   # a walk from the start would ask about 950 times
