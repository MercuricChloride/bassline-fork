## store/values: the value-typed face of the store. `incl` / `contains`
## pass CE bytes through untouched; `items` / `under` decode what the
## scan returns; `under q` is exactly the stored elements `q` prefixes.
## Writes go through `incl` inside a `withTx` -- the byte layer refuses
## an insert with no transaction open, so there are no per-value txns.

import std/[algorithm, sequtils, unittest]
import bl/core
import bl/store
import bl/lib/[ops, blah, blmacro]
import ./corpus

# the elements: every corpus value, plus random ones
var values: seq[Value]
for c in cases:
  if c.head == sym"ce": values.add c.items[2]   # the corpus's own ce cases
for val in blah(400, 3):
  values.add val

# the reference: sorted, deduped (the store is a set)
var ordered = values
ordered.sort(cmp)
block:
  var i = 1
  while i < ordered.len:
    if ordered[i] == ordered[i - 1]: ordered.delete(i)
    else: inc i

proc bytesOf(vs: seq[ValueView]): seq[seq[byte]] =
  for v in vs: result.add @(v.bytes)

suite "store/values door":
  var db = createMemDb()
  db.withTx:
    for v in values:
      db.incl v
  let snap = db.snapshot()

  test "incl needs an open transaction and reports novelty":
    expect AssertionDefect:           # the byte layer enforces it
      discard db.incl(sym"no-txn-here")
    db.withTx:
      check db.incl(values[0]) == false          # already present
      check db.incl(sym"brand-new") == true
      check db.incl(sym"brand-new") == false     # same batch
    check sym"brand-new" in db.snapshot()

  test "contains / `in`, for views and values":
    let s2 = db.snapshot()
    for v in values:
      check v in s2                               # Value overload
      check v.toView in s2                        # ValueView overload
    check sym"nowhere-near-the-store" notin s2
    check (bl !absent(1, 2)) notin s2

  test "items is every element, once, in canonical order":
    check bytesOf(toSeq(snap.items)) == ordered.mapIt(ce it)

  test "itemsFrom starts at the lower bound":
    require ordered.len > 10
    let cut = ordered.len div 2
    check bytesOf(toSeq(snap.itemsFrom(ordered[cut]))) ==
          ordered[cut .. ^1].mapIt(ce it)
    check bytesOf(toSeq(snap.itemsFrom(ordered[cut].toView))) ==
          bytesOf(toSeq(snap.itemsFrom(ordered[cut])))

  test "under q  ==  the stored elements q prefixes":
    for _ in 0 ..< 250:
      let q = randValue(3)
      var want: seq[seq[byte]]
      for e in ordered:
        if prefixes(q, e): want.add ce(e)
      check bytesOf(toSeq(snap.under(q))) == want
      check bytesOf(toSeq(snap.under(q.toView))) == want

  test "under a scalar is an exact match":
    var d = createMemDb()
    d.withTx:
      d.incl sym"alpha"
      d.incl sym"beta"
      d.incl text"alpha"
    let s = d.snapshot()
    check bytesOf(toSeq(s.under(sym"alpha"))) == @[ce sym"alpha"]
    check toSeq(s.under(sym"gamma")).len == 0
    d.close()

  test "under a marked query never crosses into unmarked values":
    var d = createMemDb()
    let plain = bl person("alice", 30)
    let acted = bl !person("alice", 30)
    d.withTx:
      d.incl plain
      d.incl acted
    let s = d.snapshot()
    check bytesOf(toSeq(s.under(bl person("alice")))) == @[ce plain]
    check bytesOf(toSeq(s.under(bl !person("alice")))) == @[ce acted]
    d.close()

  test "low / high decode the bounds":
    check @(ValueView.low(snap).bytes) == ordered[0].ce
    check @(ValueView.high(snap).bytes) == ordered[^1].ce
    check Value.low(snap) == ordered[0]
    check Value.high(snap) == ordered[^1]
    var e = createMemDb()
    expect KeyError: discard ValueView.low(e.snapshot())
    e.close()

  test "a stored value's CE bytes come back byte-identical":
    for v in ordered[0 ..< min(ordered.len, 60)]:
      check ce(v) in bytesOf(toSeq(snap.under(v)))   # v is in its own run

  db.close()
