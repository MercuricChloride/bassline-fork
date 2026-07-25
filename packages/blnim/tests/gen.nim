{.experimental: "strictFuncs".}

## gen: canonical values and pattern trees from byte strings.
##
## Everything generated goes through the constructors, so it is valid by
## construction. Feeds are plain bytes from a seeded PRNG, so every
## property is deterministic. An exhausted feed answers zeros, so
## generation always terminates in leaves.
##
## `Spec` is a pattern tree with a naive, exponential reference matcher
## (`nMatch`) and a translation into the engine (`build`); agreement
## between the two is the load-bearing property of the whole matcher.

import std/algorithm
import pkg/core
import lib/grammar

type ByteFeed* = object
  data: seq[byte]
  pos: int

func initFeed*(data: seq[byte]): ByteFeed =
  ByteFeed(data: data)

func next*(f: var ByteFeed): byte =
  if f.pos < f.data.len:
    result = f.data[f.pos]
    inc f.pos

# ================ VALUES ================

func genShortText(f: var ByteFeed): string =
  for _ in 0 ..< int(f.next mod 4):
    result.add char(ord('a') + int(f.next mod 26))

func genShortBytes(f: var ByteFeed): seq[byte] =
  for _ in 0 ..< int(f.next mod 4):
    result.add f.next

func genValue*(f: var ByteFeed, depth: int): Value

func genValues*(f: var ByteFeed, depth: int, most = 2): seq[Value] =
  for _ in 0 ..< int(f.next mod byte(most + 1)):
    result.add genValue(f, depth)

func genEntries*(f: var ByteFeed, depth: int): seq[(Value, Value)] =
  var es: seq[(Value, Value)]
  for _ in 0 ..< int(f.next mod 3):
    es.add (genValue(f, depth), genValue(f, depth))
  es = es.sortedByIt(it[0])
  for e in es:
    if result.len == 0 or result[^1][0] != e[0]:
      result.add e

func genValue*(f: var ByteFeed, depth: int): Value =
  let marked = (f.next and 1) == 1
  let op =
    if depth <= 0:
      f.next mod 5
    else:
      f.next mod 9
  case op
  of 0:
    nilValue(marked)
  of 1:
    num($(int(f.next) - 128), marked)
  of 2:
    text(f.genShortText, marked)
  of 3:
    sym(f.genShortText, marked)
  of 4:
    bytes(f.genShortBytes, marked)
  of 5:
    list(f.genValues(depth - 1), marked)
  of 6:
    var items = @[f.genValue(depth - 1)] # the head
    for x in f.genValues(depth - 1):
      items.add x
    record(items, marked)
  of 7:
    dict(f.genEntries(depth - 1), marked)
  else:
    values.set(f.genValues(depth - 1), marked)

# ================ PATTERN TREES ================

type
  SpecKind* = enum
    skEmpty
    skNever
    skChoice
    skGroup
    skStar
    skKind
    skLit
    skFrame
    skRef

  Spec* = ref object
    case kind*: SpecKind
    of skEmpty, skNever:
      discard
    of skChoice, skGroup:
      a*, b*: Spec
    of skStar:
      body*: Spec
    of skKind:
      kinds*: set[BlKind]
      req*: MarkReq
      plen*: int
    of skLit:
      lit*: Value
    of skFrame:
      fk*: BlKind
      freq*: MarkReq
      children*: Spec
    of skRef:
      ix*: int

const FrameKinds = [bList, bRecord, bDict, bSet]

func genReq(f: var ByteFeed): MarkReq =
  MarkReq(f.next mod 3)

func genKinds(f: var ByteFeed): set[BlKind] =
  let bits = int(f.next) or (int(f.next) shl 8)
  for k in BlKind:
    if ((bits shr ord(k)) and 1) == 1:
      result.incl k
  if result == {}:
    result = AllKinds

func genSpec*(f: var ByteFeed, depth: int, nrules = 0): Spec =
  let op =
    if depth <= 0:
      f.next mod 3
    elif nrules > 0:
      f.next mod 9
    else:
      f.next mod 8
  case op
  of 0:
    let plen =
      if f.next mod 4 == 0:
        int(f.next mod 4)
      else:
        -1
    Spec(kind: skKind, kinds: f.genKinds, req: f.genReq, plen: plen)
  of 1:
    Spec(kind: skLit, lit: f.genValue(1))
  of 2:
    Spec(kind: skEmpty)
  of 3:
    Spec(
      kind: skChoice, a: f.genSpec(depth - 1, nrules), b: f.genSpec(depth - 1, nrules)
    )
  of 4:
    Spec(
      kind: skGroup, a: f.genSpec(depth - 1, nrules), b: f.genSpec(depth - 1, nrules)
    )
  of 5:
    Spec(kind: skStar, body: f.genSpec(depth - 1, nrules))
  of 6:
    Spec(
      kind: skFrame,
      fk: FrameKinds[f.next mod 4],
      freq: f.genReq,
      children: f.genSpec(depth - 1, nrules),
    )
  of 7:
    Spec(kind: skNever)
  else:
    Spec(kind: skRef, ix: int(f.next mod byte(max(nrules, 1))))

func genSpecRules*(f: var ByteFeed, n: int): seq[Spec] =
  ## a small rule table; refs in any generated spec index into it, so
  ## mutual and frame-guarded recursion both arise
  for _ in 0 ..< n:
    result.add f.genSpec(2, n)

func build*(g: var Grammar, s: Spec, refIds: openArray[PatId] = []): PatId =
  ## the same tree through the smart constructors; `refIds` maps
  ## skRef indexes to refTo patterns
  case s.kind
  of skEmpty:
    g.empty
  of skNever:
    g.never
  of skChoice:
    g.choice(g.build(s.a, refIds), g.build(s.b, refIds))
  of skGroup:
    g.group(g.build(s.a, refIds), g.build(s.b, refIds))
  of skStar:
    g.star(g.build(s.body, refIds))
  of skKind:
    g.kindOf(s.kinds, s.req, s.plen)
  of skLit:
    g.lit(s.lit)
  of skFrame:
    g.frame(s.fk, g.build(s.children, refIds), s.freq)
  of skRef:
    refIds[s.ix]

# ================ NAIVE REFERENCE MATCHER ================
# Exponential and obviously right; the engine must agree with it.

func reqOk(req: MarkReq, v: Value): bool =
  case req
  of mrInert:
    not v.marked
  of mrMarked:
    v.marked
  of mrAny:
    true

func elems(v: Value): seq[Value] =
  for c in v.children:
    result.add c

func nMatch*(
  s: Spec,
  vs: openArray[Value],
  lo, hi: int,
  rs: openArray[Spec] = [],
  guard: seq[(int, int, int)] = @[],
): bool

func nAdmits(s: Spec, v: Value, rs: openArray[Spec]): bool =
  case s.kind
  of skKind:
    v.kind in s.kinds and reqOk(s.req, v) and (s.plen < 0 or v.payloadLength == s.plen)
  of skLit:
    v == s.lit
  of skFrame:
    # a fresh guard: the child slice indexes a different sequence
    let es = elems(v)
    v.kind == s.fk and reqOk(s.freq, v) and nMatch(s.children, es, 0, es.len, rs)
  else:
    false

func nMatch*(
    s: Spec,
    vs: openArray[Value],
    lo, hi: int,
    rs: openArray[Spec] = [],
    guard: seq[(int, int, int)] = @[],
): bool =
  ## does `s` admit the slice `vs[lo ..< hi]`; `rs` resolves skRef.
  ## `guard` cuts same-slice rule re-entry: the engine prunes vacuous
  ## ref cycles structurally (never-annihilation), so the raw spec can
  ## still hold one — a rule re-entered on an unshrunk slice adds no
  ## derivation, so it answers false along this path.
  case s.kind
  of skEmpty:
    lo == hi
  of skNever:
    false
  of skChoice:
    nMatch(s.a, vs, lo, hi, rs, guard) or nMatch(s.b, vs, lo, hi, rs, guard)
  of skGroup:
    for mid in lo .. hi:
      if nMatch(s.a, vs, lo, mid, rs, guard) and nMatch(s.b, vs, mid, hi, rs, guard):
        return true
    false
  of skStar:
    if lo == hi:
      return true
    for mid in (lo + 1) .. hi:
      if nMatch(s.body, vs, lo, mid, rs, guard) and nMatch(s, vs, mid, hi, rs, guard):
        return true
    false
  of skRef:
    if (s.ix, lo, hi) in guard:
      false
    else:
      nMatch(rs[s.ix], vs, lo, hi, rs, guard & @[(s.ix, lo, hi)])
  of skKind, skLit, skFrame:
    lo + 1 == hi and nAdmits(s, vs[lo], rs)

func nMatches*(s: Spec, vs: openArray[Value], rs: openArray[Spec] = []): bool =
  nMatch(s, vs, 0, vs.len, rs)

func agreeCase*(data: seq[byte]): Option[(bool, bool, bool)] =
  ## the load-bearing differential recipe: a small mutually-referential
  ## spec grammar and a start spec from the feed, one generated value
  ## list, both matchers. Answers (oracle, engine, engine again — pool
  ## growth must never move a verdict); none when the spec grammar is
  ## refused at seal or the judgment refuses on budget.
  const N = 3
  var f = initFeed(data)
  var g = initGrammar()
  var refIds: seq[PatId]
  for j in 0 ..< N:
    refIds.add g.refTo("r" & $j)
  let rs = f.genSpecRules(N)
  let s = f.genSpec(3, N)
  try:
    for j in 0 ..< N:
      g.rule("r" & $j, g.build(rs[j], refIds))
    g.rule "t", g.frame(bList, g.build(s, refIds))
    g.seal()
  except GrammarError:
    return # unguarded or odd-parity spec grammars are refused
  var vs: seq[Value]
  for _ in 0 ..< int(f.next mod 5):
    vs.add f.genValue(2)
  let lv = list(vs)
  let want = nMatches(s, vs, rs)
  try:
    result = some((want, g.matches("t", lv), g.matches("t", lv)))
  except BudgetError:
    discard # refusal is not disagreement

# ================ GRAMMAR VALUES ================

func genPatV*(f: var ByteFeed, depth: int): Value =
  ## a pattern in the grammar dialect, mostly valid by construction so
  ## the loader and the self-description get exercised on both sides
  func o(name: string, ops: varargs[Value]): Value =
    record(@[sym(name)] & @ops, marked = true)

  let op =
    if depth <= 0:
      f.next mod 4
    else:
      f.next mod 11
  case op
  of 0:
    o("lit", f.genValue(1))
  of 1:
    let kinds = [o("any"), o("num"), o("text"), o("sym"), o("bytes")]
    kinds[int(f.next mod 5)]
  of 2:
    o("bytes", num($int(f.next mod 40)))
  of 3:
    # a reference; may dangle or cycle. NOTE: spelled via the ctor —
    # `mark names[int(f.next mod 3)]` (sink of an element whose index
    # expression mutates f) miscompiles on Nim 2.2.10 and corrupts the
    # heap; see the seq-hook landmine notes
    let names = ["start", "a", "b"]
    sym(names[int(f.next mod 3)], marked = true)
  of 4:
    o("or", f.genPatV(depth - 1), f.genPatV(depth - 1))
  of 5:
    o("*", f.genPatV(depth - 1))
  of 6:
    o("?", f.genPatV(depth - 1))
  of 7:
    list(@[f.genPatV(depth - 1), f.genPatV(depth - 1)])
  of 8:
    # sometimes an operator's name on an inert head: still a template,
    # and the loader and self-description must agree on that reading
    let hi = int(f.next mod 4)
    let heads = [f.genShortText & "h", "lit", "?", "*"]
    record(@[sym(heads[hi]), f.genPatV(depth - 1)])
  of 9:
    dict(@[(sym(f.genShortText), f.genPatV(depth - 1))])
  else:
    # a frame kind operator, bare or quantifying its children; odd
    # children in dict position are parity refusals, also worth feeding
    let fks = ["list", "record", "dict", "set"]
    let fk = fks[int(f.next mod 4)]
    if f.next mod 2 == 0:
      o(fk)
    else:
      o(fk, f.genPatV(depth - 1))

func genGrammarValue*(f: var ByteFeed): Value =
  ## a small grammar value over rules start/a/b; invalid spellings and
  ## unsealable tables arise from the same feed and must refuse cleanly
  var rules = @[(sym"start", f.genPatV(2))]
  if f.next mod 2 == 1:
    rules.add (sym"a", f.genPatV(2))
  if f.next mod 2 == 1:
    rules.add (sym"b", f.genPatV(2))
  record(@[sym"grammar", dict(rules)], marked = true)
