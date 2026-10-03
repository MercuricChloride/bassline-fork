## rewrite: shapes with holes, and the search for what fills them

import std/[unittest, options, random, sets]
import bl/core
import bl/lib/blmacro
import bl/queries

template refuses(call: untyped) =
  expect ValueError:
    discard call

proc shape(text: string): Shape = Shape.fromValue(readValue(text))

proc fills(s: Shape, text: string): seq[Value] =
  ## every filling of the value `text` reads as, in the order found
  s.fillings(readValue(text)).collect

proc dicts(texts: varargs[string]): seq[Value] =
  for t in texts: result.add readValue(t)

proc sameAs(a, b: seq[Value]): bool =
  ## the same bindings, in any order
  initSet(a) == initSet(b)

suite "fillings":
  test "a plain shape fills a value with the example's members leading":
    let file = shape("(shape (file name digest) {name digest})")
    check file.fills("(file \"a.txt\" 0xff extra)") == dicts("{name: \"a.txt\" digest: 0xff}")
    check file.fills("(dir \"a.txt\" 0xff)").len == 0
    check file.fills("(file)").len == 0

  test "a hole met again fits only what it is bound to":
    let twice = shape("(shape [x y x] {x y})")
    check twice.fills("[1 2 1]") == dicts("{x: 1 y: 2}")
    check twice.fills("[1 2 3]").len == 0          # no filling, not an error

  test "a hole in a set member is tried against every member":
    check shape("(shape {(tag t)} {t})").fills("{(tag a) (tag b) (other c)}").sameAs(
      dicts("{t: a}", "{t: b}"))
    let member = shape("(shape {a x} {x})")
    check member.fills("{a b c}").sameAs(dicts("{x: a}", "{x: b}", "{x: c}"))
    check member.fills("{b c}").len == 0           # a literal member is still needed
    check shape("(shape {[x] [y]} {x y})").fills("{[1] [2]}").sameAs(
      dicts("{x: 1 y: 1}", "{x: 1 y: 2}", "{x: 2 y: 1}", "{x: 2 y: 2}"))

  test "a hole in a dict key is tried against every entry":
    check shape("(shape {k: v} {k v})").fills("{a: 1 b: 2}").sameAs(
      dicts("{k: a v: 1}", "{k: b v: 2}"))
    check shape("(shape {k: k} {k})").fills("{a: b c: c 1: 1}").sameAs(
      dicts("{k: c}", "{k: 1}"))
    check shape("(shape {(k x): 1} {x})").fills("{(k 5): 1 (k 6): 2 (j 7): 1}") ==
      dicts("{x: 5}")
    check shape("(shape {a: x} {x})").fills("{a: 1 b: 2}") == dicts("{x: 1}")

  test "marks must agree, and the wild fits anything and binds nothing":
    check shape("(shape {(op x)} {x})").fills("{(op go) (op go!)}") == dicts("{x: go}")
    check shape("(shape {(op x!)} {x!})").fills("{(op go) (op go!)}") == dicts("{x!: go!}")
    check shape("(shape !(f x) {x})").fills("(f 1)").len == 0
    let wild = shape("(shape {(p x) (q _)} {x} _)")
    check wild.fills("{(p 1) (q 1) (q 2)}") == dicts("{x: 1}")   # once, though two fit the wild
    check wild.fills("{(p 1)}").len == 0

  test "every hole must be bound":
    check shape("(shape (f x) {x y})").fills("(f 1)").len == 0
    check shape("(shape [(k x)] {x (k x)})").fills("[(k 1)]").len == 0   # inside another hole

  test "a search can start from bindings already had":
    let row = shape("(shape (row label n) {label n})")
    check row.fillings(bl(row(a, 1)), bl({label: a})).collect == @[bl({label: a, n: 1})]
    check row.fillings(bl(row(a, 1)), bl({label: b})).collect.len == 0
    check row.fillings(bl(row(a, 1)), bl({seen: yes})).collect ==   # what it doesn't bind rides along
      @[bl({label: a, n: 1, seen: yes})]
    refuses row.fillings(bl(row(a, 1)), bl([label, a]))

  test "nothing is worked out ahead of a pull":
    var members = newBSet()
    for i in 0 ..< 200: members.incl initList(@[toValue(i)])
    let three = shape("(shape {[x] [y] [z]} {x y z})")
    let first = three.fillings(initSet(members)).take(3)   # eight million, three taken
    check first.len == 3 and initSet(first).els.len == 3

  test "what the bindings decide is checked before anything branches":
    var lists = newBSet()
    for i in 0 ..< 1000: lists.incl initList(@[toValue(i)])
    # (stop) sorts after the lists; checked last, it would fail a million times
    check shape("(shape {(stop) [x] [y]} {x y})").fills($initSet(lists)).len == 0
    var graph = newBSet()
    for i in 0 ..< 1000:
      graph.incl initRec(@[sym"edge", toValue(i), toValue(i + 1)])
      graph.incl initRec(@[sym"node", toValue(i)])
    # each edge found by bisecting on the members bound already
    check shape("(shape {(edge x y) (edge y z) (node z)} {x y z})").fills(
      $initSet(graph)).len == 998

suite "a shape as a search":
  test "asked about a value, it answers every filling, and composes":
    let row = shape("(shape (row label n) {label n})").search
    check row[bl(row(a, 1))].collect == @[bl({label: a, n: 1})]
    check (row ? bl(note(x))).isNone
    let rows = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      initStream(@[bl(row(a, 1)), bl(note(x)), bl(row(b, 2))]))
    check feed(rows, row)[bl anything].collect ==
      @[bl({label: a, n: 1}), bl({label: b, n: 2})]

suite "written down, and filled":
  test "a shape reads and writes as (shape EXAMPLE {HOLE …} WILD)":
    for text in ["(shape (f x) {x})", "(shape (f x _) {x} _)"]:
      check shape(text).toValue == readValue(text)
    refuses shape("(shape (f x))")
    refuses shape("(shape (f x) [x])")
    refuses shape("!(shape (f x) {x})")
    refuses shape("(form (f x) {x})")

  test "inject fills the holes bound, and leaves the rest":
    let s = shape("(shape !{(cmd c): [arg x] other: y} {c x y})")
    check s.inject(bl({c: go, x: 1})) == readValue("!{(cmd go): [arg 1] other: y}")
    check s.inject(s.fillings(readValue("!{(cmd go): [arg 1] other: 2}"))[].get) ==
      readValue("!{(cmd go): [arg 1] other: 2}")
    refuses s.inject(bl([c, go]))

# ================ against a brute-force search ================

proc literal(s: Shape, part: Value): bool =
  for p in part.walk:
    if p in s.holes or s.wild == some(p): return false
  true

proc fits(s: Shape, part, v, b: Value): bool =
  ## what a filling is, said directly: under the bindings `b`, `v` fits
  ## `part`, as quantifiers over the value's own keys and members
  if s.wild == some(part): return true
  if part in s.holes: return part.mark == v.mark and part in b.dict and b.dict[part] == v
  if part.kind != v.kind or part.mark != v.mark: return false
  case part.kind
  of bList, bRec:
    if v.items.len < part.items.len: return false
    for i in 0 ..< part.items.len:
      if not fits(s, part.items[i], v.items[i], b): return false
    true
  of bDict:
    part.entries.every(proc(e: (Value, Value)): bool =
      let (key, item) = e
      if literal(s, key): key in v.dict and fits(s, item, v.dict[key], b)
      else: v.entries.exists(proc(f: (Value, Value)): bool =
        fits(s, key, f[0], b) and fits(s, item, f[1], b)))
  of bSet:
    part.members.every(proc(m: Value): bool =
      if literal(s, m): m in v.els
      else: v.members.exists(Value -> fits(s, m, it, b)))
  else: part == v

proc reaches(s: Shape, hole, part: Value): bool =
  ## whether matching ever gets to `hole` in `part`: not under the wild,
  ## nor inside another hole
  if s.wild == some(part): return false
  if part in s.holes: return part == hole
  part.parts.exists(Value -> reaches(s, hole, it))

proc bruteForce(s: Shape, v: Value, most = 20_000):
    Option[HashSet[seq[byte]]] =
  ## every filling, by trying every assignment of the value's parts to the
  ## holes: a hole binds what is in its place, so one of them, and of its
  ## own mark. None when there are more than `most` assignments to try
  let holes = collect(s.holes.between(always, always))
  if not initStream(holes).every(Value -> reaches(s, it, s.example)):
    return some initHashSet[seq[byte]]()
  let parts = collect(unique(v.walk))
  var candidates: seq[seq[Value]]
  var tries = 1
  for h in holes:
    let mark = h.mark
    candidates.add collect(initStream(parts).filter(Value -> it.mark == mark))
    tries *= max(candidates[^1].len, 1)
    if tries > most: return none(HashSet[seq[byte]])
  let found = new HashSet[seq[byte]]
  proc assign(i: int, b: BDict) =
    if i == holes.len:
      let binding = initDict(b)
      if fits(s, s.example, v, binding): found[].incl binding.ce
      return
    for c in candidates[i]:
      let next = b + newBDict()
      next[holes[i]] = c
      assign(i + 1, next)
  assign(0, newBDict())
  some found[]

proc small(r: var Rand, depth = 0): Value =
  ## small values from a small alphabet, so parts repeat and shapes find
  ## several ways to fill
  if depth >= 3 or r.rand(if depth == 0: 5 else: 2) == 0:
    result = [bl 0, bl 1, bl 2, bl a, bl b, bl c, bl "", bl "t", bl nil][r.rand(8)]
  else:
    var members: seq[Value]
    for _ in 0 ..< r.rand(3): members.add r.small(depth + 1)
    case r.rand(3)
    of 0: result = initList(members)
    of 1: result = initRec(@[if r.rand(2) == 0: r.small(3) else: [bl p, bl q][r.rand(1)]] & members)
    of 2:
      var entries: seq[(Value, Value)]
      for m in members: entries.add (r.small(depth + 2), m)
      let d = newBDict()
      for (k, x) in entries: d[k] = x
      result = initDict(d)
    else: result = initSet(toBTreeSet(members))
  if r.rand(9) == 0: result.mark = true

proc punch(r: var Rand, part: Value, holes: var seq[Value], depth = 0): Value =
  ## `part` with holes, some repeated, and the wild in place of some of its
  ## parts, anywhere: keys, members and heads too
  if depth > 0 and r.rand(3) == 0:
    if r.rand(4) == 0: return bl `_`
    result = [bl x, bl y, bl z][r.rand(2)]
    result.mark = if r.rand(5) == 0: not part.mark else: part.mark
    holes.add result
    return
  case part.kind
  of bList, bRec:
    var items: seq[Value]
    for p in part.items.data: items.add r.punch(p, holes, depth + 1)
    if part.kind == bList: initList(items, part.mark) else: initRec(items, part.mark)
  of bDict:
    let d = newBDict()
    for k, x in part.dict: d[r.punch(k, holes, depth + 1)] = r.punch(x, holes, depth + 1)
    initDict(d, part.mark)
  of bSet:
    var members: seq[Value]
    for m in part.els: members.add r.punch(m, holes, depth + 1)
    initSet(members, part.mark)
  else: part

suite "fillings against brute force":
  test "fillings are exactly the bindings under which the value fits":
    var r = initRand(2026_10_03)
    var filled, skipped = 0
    for _ in 0 ..< 400:
      let v = r.small
      var holes: seq[Value]
      let example = r.punch(v, holes)
      if r.rand(14) == 0: holes.add bl never
      let s = initShape(example, holes, some(bl `_`))
      let brute = bruteForce(s, v)
      if brute.isNone:
        inc skipped           # too many assignments to try them all
        continue
      var found = initHashSet[seq[byte]]()
      for b in s.fillings(v): found.incl b.ce
      check found == brute.get
      if found.len > 0: inc filled
    check filled > 100        # most cases have a filling to compare
    check skipped < 20
