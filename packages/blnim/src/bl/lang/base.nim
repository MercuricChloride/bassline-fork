## A base vocabulary: enough to write functions, rules, tests and loops
## as values, and to make and take apart frames. None of it is the
## meaning of its heads; it is one set of doers a cx may hold, and any
## other may stand nearer.
##
## Doing:
##   !(do BLOCK)                 the block done, each form once for each
##                               answer of the one before
##   !(if TEST YES NO?)          YES done if TEST answers, else NO
##   !(else A B)                 A's answers, or else B's
##   !(then TEST YES)            YES, for each answer of TEST
##   !(case V {K: BLOCK …})      the block under V
##   !(quote [V])                V, as written, marked or not
##
## A test is a block, so that answering nothing can be seen: the direct
## marked arguments of a call are done before it, and an argument with no
## answer leaves no call to make.
##
## Answers and values:
##   !(all BLOCK)  !(first BLOCK)  !(count BLOCK)  !(take N BLOCK)
##   !(in FRAME)                 each member: a list's or set's, a
##                               record's fields, a dict's [KEY VALUE]
##   ![…]  !{K: V …}  !{…}       the frame with its direct marked parts done
##   !(record HEAD ARG …)        (HEAD ARG …), a record made, not a call
##
## Functions and rules:
##   !(fn [PARAM …] BODY)        a function: (fn [PARAM …] BODY CAPTURED)
##   !(fn NAME [PARAM …] BODY)   one that calls itself NAME
##   !(f! ARG …)                 a function in a variable, applied
##   !(let {NAME: VALUE …} BODY) BODY with the names bound; a value
##                               worked out is a marked dict's, !{…}
##   (rule (shape EXAMPLE {HOLE …}) BODY)
##                               a call fitting EXAMPLE, its holes bound;
##                               the first rule that answers answers
##
## A function's value carries the variables its body mentions, CAPTURED,
## so it can go anywhere a value can; the doers its body calls are found
## where it is applied.
##
## Numbers, tests and frames:
##   !(add A B) !(sub A B) !(mul A B) !(div A B) !(mod A B) !(sum [N …])
##   !(lt A B) !(le A B) !(gt A B) !(ge A B)  A, if it holds; else nothing
##   !(eq A B) !(ne A B)         A, if it holds; else nothing
##   !(compare A B)              lt, eq or gt: numbers by number, else CE
##   !(range N) !(range A B)     [A … B-1], up to MaxRange members
##   !(len V) !(get V K)         a frame's width; a dict's value or a
##                               list's member
##   !(has F X) !(lacks F X)     X, if F holds it (a member, or a dict's
##                               key), or if it doesn't; else nothing
##   !(fill SHAPE V)             each filling of the shape by V
##   !{!(kind find) …}           what a find finds (bl/queries/find)
##   !(inject SHAPE BINDINGS)
##
## Asking about doing:
##   !(describe HEAD)            each signature in reach for HEAD
##   !(readings [CALL])          every doer's answers, not only the first's
##
## Arithmetic holds what the host's integers hold and refuses past it.

import std/[options, sequtils, tables]
import ../queries/rewrite as rw
import ./[kernel, native]
export kernel, native

refuseWith BasslineError

const MaxRange* {.intdefine.} = 1 shl 24
  ## the widest list `range` makes

moldable """{
  !(struct do {exact (rep record)} (body any))
  !(struct if {exact (rep record)} (test any) (yes any) (no {optional} any))
  !(struct else {exact (rep record)} (first any) (second any))
  !(struct then {exact (rep record)} (test any) (yes any))
  !(struct case {exact (rep record)} (on any) (cases dict))
  !(struct quote {exact (rep record)} (it list))

  !(struct all {exact (rep record)} (body any))
  !(struct first {exact (rep record)} (body any))
  !(struct count {exact (rep record)} (body any))
  !(struct take {exact (rep record)} (n number) (body any))
  !(struct in {exact (rep record)} (frame any))

  !(struct let {exact (rep record)} (bindings dict) (body any))

  !(struct add {exact (rep record)} (a number) (b number))
  !(struct sub {exact (rep record)} (a number) (b number))
  !(struct mul {exact (rep record)} (a number) (b number))
  !(struct div {exact (rep record)} (a number) (b number))
  !(struct mod {exact (rep record)} (a number) (b number))
  !(struct sum {exact (rep record)} (numbers [number]))
  !(struct lt {exact (rep record)} (a number) (b number))
  !(struct le {exact (rep record)} (a number) (b number))
  !(struct gt {exact (rep record)} (a number) (b number))
  !(struct ge {exact (rep record)} (a number) (b number))
  !(struct eq {exact (rep record)} (a any) (b any))
  !(struct ne {exact (rep record)} (a any) (b any))
  !(struct compare {exact (rep record)} (a any) (b any))
  !(struct range {exact (rep record)} (a number) (b {optional} number))

  !(struct len {exact (rep record)} (frame any))
  !(struct has {exact (rep record)} (frame any) (member any))
  !(struct lacks {exact (rep record)} (frame any) (member any))
  !(struct get {exact (rep record)} (frame any) (key any))
  !(struct fill {exact (rep record)} (pattern any) (subject any))
  !(struct inject {exact (rep record)} (pattern any) (bindings dict))

  !(struct describe {exact (rep record)} (name any))
  !(struct readings {exact (rep record)} (body any))
}"""

# ================ numbers ================

proc host(n: BNum, what: string): int =
  guard n.isInt, what & " is past what this host's integers hold: " & $n
  n.toInt

proc answer(n: int): Stream[Value] = just num(n)

proc added*(a, b: int): int =
  guard not ((b > 0 and a > high(int) - b) or (b < 0 and a < low(int) - b)),
    "add: past what this host's integers hold"
  a + b

proc subtracted*(a, b: int): int =
  guard not ((b < 0 and a > high(int) + b) or (b > 0 and a < low(int) + b)),
    "sub: past what this host's integers hold"
  a - b

proc multiplied*(a, b: int): int =
  let over =
    if a > 0:
      if b > 0: a > high(int) div b else: b < low(int) div a
    elif a < 0:
      if b > 0: a < low(int) div b else: b < high(int) div a
    else: false
  guard not over, "mul: past what this host's integers hold"
  a * b

method run(c: Add, cx: Cx): Stream[Value] =
  answer added(c.a.host("add"), c.b.host("add"))

method run(c: Sub, cx: Cx): Stream[Value] =
  answer subtracted(c.a.host("sub"), c.b.host("sub"))

method run(c: Mul, cx: Cx): Stream[Value] =
  answer multiplied(c.a.host("mul"), c.b.host("mul"))

method run(c: Div, cx: Cx): Stream[Value] =
  let (a, b) = (c.a.host("div"), c.b.host("div"))
  guard b != 0, "div by zero"
  guard not (a == low(int) and b == -1), "div: past what this host's integers hold"
  answer a div b

method run(c: Mod, cx: Cx): Stream[Value] =
  let (a, b) = (c.a.host("mod"), c.b.host("mod"))
  guard b != 0, "mod by zero"
  answer(if b == -1: 0 else: a mod b)

method run(c: Sum, cx: Cx): Stream[Value] =
  var total = 0
  for n in c.numbers: total = added(total, n.host("sum"))
  answer total

template holds(T, op) =
  method run(c: T, cx: Cx): Stream[Value] =
    if op(c.a, c.b): just c.a.toValue else: empty Value

holds Lt, `<`
holds Le, `<=`
holds Gt, `>`
holds Ge, `>=`

method run(c: Eq, cx: Cx): Stream[Value] =
  if c.a == c.b: just c.a else: empty Value

method run(c: Ne, cx: Cx): Stream[Value] =
  if c.a != c.b: just c.a else: empty Value

method run(c: Compare, cx: Cx): Stream[Value] =
  let order =
    if c.a.isKind(bNum, unmarked) and c.b.isKind(bNum, unmarked):
      cmp(c.a.num, c.b.num)
    else: cmp(c.a, c.b)
  just sym(if order < 0: "lt" elif order == 0: "eq" else: "gt")

method run(c: Range, cx: Cx): Stream[Value] =
  let (lo, hi) =
    if c.b.isSome: (c.a.host("range"), c.b.get.host("range"))
    else: (0, c.a.host("range"))
  let width = if hi > lo: subtracted(hi, lo) else: 0
  guard width <= MaxRange, "range: wider than " & $MaxRange & " members"
  var items = newSeqOfCap[Value](width)
  for i in lo ..< hi: items.add num(i)
  just initList(items)

# ================ doing ================

method run(c: Do, cx: Cx): Stream[Value] = cx.run(c.body)

method run(c: If, cx: Cx): Stream[Value] =
  let (test, yes, no) = (c.test, c.yes, c.no)
  lazy(() => (block:
    if cx.run(test)().isSome: cx.run(yes)
    elif no.isSome: cx.run(no.get)
    else: empty(Value)))

method run(c: Else, cx: Cx): Stream[Value] =
  let (a, b) = (c.first, c.second)
  var s: Stream[Value] = nil
  () -> Option[Value] => (block:
    if s == nil:
      s = cx.run(a)
      result = s()
      if result.isSome: return
      s = cx.run(b)
    result = s())

method run(c: Then, cx: Cx): Stream[Value] = just c.yes

method run(c: Case, cx: Cx): Stream[Value] =
  if c.on in c.cases: cx.run(c.cases[c.on]) else: empty Value

method run(c: Quote, cx: Cx): Stream[Value] =
  guard c.it.len == 1, "quote takes a list of one: !(quote [V])"
  just c.it[0]

# ================ answers and values ================

method run(c: All, cx: Cx): Stream[Value] =
  let b = c.body
  lazy(() => just initList(cx.run(b).toSeq))

method run(c: First, cx: Cx): Stream[Value] =
  let b = c.body
  lazy(() => (block:
    let a = cx.run(b)()
    if a.isSome: just(a.get) else: empty(Value)))

method run(c: Count, cx: Cx): Stream[Value] =
  let b = c.body
  lazy(() => (block:
    var n = 0
    for _ in cx.run(b): inc n
    answer(n)))

method run(c: Take, cx: Cx): Stream[Value] =
  let n = c.n.host("take")
  guard n >= 0, "take a negative count"
  var (s, taken) = (cx.run(c.body), 0)
  () -> Option[Value] => (block:
    if taken >= n: return
    result = s()
    # an ended body is not pulled again
    if result.isSome: inc taken else: taken = n)

method run(c: In, cx: Cx): Stream[Value] =
  let f = c.frame
  case f.kind
  of bList: initStream(f.items.data)
  of bRec: initStream(f.items.data[1 .. ^1])
  of bSet: f.members
  of bDict: f.entries.maps(initList(@[it[0], it[1]]))
  else: empty Value

type Reduce = ref object of Doer
  ## a marked list, dict or set made with its direct marked parts done

method fits(d: Reduce, v: Value): bool =
  v.isKind({bList, bDict, bSet})

method answers(d: Reduce, v: Value, cx: Cx): Stream[Value] =
  case v.kind
  of bList:
    cx.doneItems(v.items.data, 0, items => initList(items))
  of bSet:
    cx.doneItems(v.members.toSeq, 0, items => (block:
      let made = initSet(items)
      guard(made.len == items.len, "a set made with a member twice")
      made))
  else:
    var flat: seq[Value]
    for k, x in v.dict:
      flat.add k
      flat.add x
    cx.doneItems(flat, 0, items => (block:
      var entries: seq[(Value, Value)]
      for i in countup(0, items.high, 2): entries.add (items[i], items[i + 1])
      let made = initDict(entries)
      guard(made.len == entries.len, "a dict made with a key twice")
      made))

let RecordQ = sym"record"

type Make = ref object of Doer
  ## !(record HEAD ARG …), its direct marked arguments done: (HEAD ARG …)

method fits(d: Make, v: Value): bool = v.isKind(bRec) and v.items.len >= 2

method answers(d: Make, v: Value, cx: Cx): Stream[Value] =
  just initRec(v.items.data[1 .. ^1])

method describe(d: Make): Value = rv"!(record head arg)"

# ================ functions ================

let FnQ = sym"fn"

proc isParams(v: Value): bool =
  v.isKind(bList, unmarked) and v.parts.every(p => p.isKind(bSym, unmarked))

proc isName(v: Value): bool = v.isKind(bSym, unmarked)

proc isClosure*(f: Value): bool =
  ## (fn [PARAM …] BODY CAPTURED) or (fn NAME [PARAM …] BODY CAPTURED)
  f.isKind(bRec, unmarked) and f.items[0] == FnQ and (
    (f.items.len == 4 and f.items[1].isParams and f.items[3].isKind(bDict, unmarked)) or
    (f.items.len == 5 and f.items[1].isName and f.items[2].isParams and
      f.items[4].isKind(bDict, unmarked)))

type Fn = ref object of Doer
  ## functions made, as values, and applied

proc making(v: Value): bool =
  ## !(fn [PARAM …] BODY) or !(fn NAME [PARAM …] BODY)
  v.items[0] == FnQ and (
    (v.items.len == 3 and v.items[1].isParams) or
    (v.items.len == 4 and v.items[1].isName and v.items[2].isParams))

method fits(d: Fn, v: Value): bool =
  if not v.isKind(bRec): return false
  if v.making: return true
  let f = v.items[0]
  f.isClosure and v.items.len - 1 == f.items[^3].items.len

method describe(d: Fn): Value =
  rv"{!(fn params body) !(fn name params body) !((fn params body captured) arg)}"

proc capturing(cx: Cx, body: Value, own: seq[Value]): Value =
  ## the bindings in reach of the variables body mentions, but `own`
  var caught = initDict()
  for part in body.walk:
    if part.isKind(bSym, marked):
      let name = sym(part.text)
      if name notin own and name notin caught.dict:
        let x = cx.lookup(name)
        if x.isSome: caught[name] = x.get
  caught

method answers(d: Fn, v: Value, cx: Cx): Stream[Value] =
  if v.making:
    let named = v.items.len == 4
    let params = v.items[^2]
    var own = params.items.data
    if named: own.add v.items[1]
    var items = v.items.data
    items.add cx.capturing(v.items[^1], own)
    return just initRec(items)
  let f = v.items[0]
  let params = f.items[^3].items.data
  var vars = f.items[^1].copy
  if f.items.len == 5: vars[f.items[1]] = f
  for i, p in params: vars[p] = v.items[i + 1]
  cx.within(vars.dict, sealed = true, deeper = true).run(f.items[^2])

method run(c: Let, cx: Cx): Stream[Value] =
  cx.within(c.bindings).run(c.body)

# ================ rules ================

let RuleQ = sym"rule"

type Rule* = ref object of Doer
  ## a call fitting the rule's example: its body done with the example's
  ## holes bound. Rules for one head are tried in the order given, as any
  ## doers are, and the first that answers gives its answers
  shape: rw.Shape
  body: Value

proc rules*(values: openArray[Value]): seq[(Value, Rule)] =
  ## the rules among values, `(rule (shape EXAMPLE {HOLE …}) BODY)`, each
  ## with the head of its example, in the order given
  for r in values:
    guard r.isKind(bRec, unmarked) and r.items.len == 3 and r.items[0] == RuleQ,
      "a rule is (rule (shape EXAMPLE {HOLE …}) BODY): " & $r
    let s = rw.Shape.fromValue(r.items[1])
    guard s.example.isKind(bRec, marked) and s.example.items.len > 0,
      "a rule's example is a call: " & $s.example
    result.add (s.example.items[0], Rule(shape: s, body: r.items[2]))

proc install*(cx: Cx, rs: openArray[(Value, Rule)]) =
  for (head, r) in rs: cx.install(head, r)

method fits(d: Rule, v: Value): bool =
  ## a call as wide as the example, at least: whether it fills is what
  ## answering finds out, and one that doesn't answers nothing
  v.isKind(bRec, marked) and v.items.len >= d.shape.example.items.len

method describe(d: Rule): Value =
  initRec(@[RuleQ, d.shape.toValue, d.body])

method answers(d: Rule, v: Value, cx: Cx): Stream[Value] =
  let body = d.body
  d.shape.fillings(v).fair(b => cx.within(b.dict, sealed = true, deeper = true).run(body),
                           cx.refused)

# ================ frames and shapes ================

method run(c: Len, cx: Cx): Stream[Value] =
  guard c.frame.isKind({bList, bRec, bDict, bSet}), "len of an atom"
  answer c.frame.len

proc holding(f, x: Value): bool =
  case f.kind
  of bList, bRec: x in f.items.data
  of bSet: x in f.els
  of bDict: x in f.dict
  else: false

method run(c: Has, cx: Cx): Stream[Value] =
  if c.frame.holding(c.member): just c.member else: empty Value

method run(c: Lacks, cx: Cx): Stream[Value] =
  if c.frame.holding(c.member): empty Value else: just c.member

method run(c: Get, cx: Cx): Stream[Value] =
  let (f, k) = (c.frame, c.key)
  case f.kind
  of bDict:
    if k in f.dict: just f.dict[k] else: empty Value
  of bList:
    if k.isKind(bNum) and k.num.isInt and k.num.toInt in 0 ..< f.items.len:
      just f.items[k.num.toInt]
    else: empty Value
  else: empty Value

method run(c: Fill, cx: Cx): Stream[Value] =
  rw.Shape.fromValue(c.pattern).fillings(c.subject)

method run(c: Inject, cx: Cx): Stream[Value] =
  just rw.Shape.fromValue(c.pattern).inject(initDict(c.bindings))

# ================ asking about doing ================

method run(c: Describe, cx: Cx): Stream[Value] =
  cx.doersFor(initRec(@[c.name], mark = true)).maps(it.describe).filters(not it.isKind(bNil))

method run(c: Readings, cx: Cx): Stream[Value] =
  guard c.body.isKind(bList) and c.body.len == 1,
    "readings takes a block of one call: !(readings [CALL])"
  cx.readings(c.body.items[0])

# ================ finds ================

type Finding = ref object of Doer
  ## a find object, brought about: what it finds
  resolve: Search[Value, Value]

method answers(d: Finding, v: Value, cx: Cx): Stream[Value] =
  rows(v, resolve = d.resolve).maps(it.answer)

method describe(d: Finding): Value =
  rv"!{!(kind search-space) !(kind find) (of subject) (hole h) (where clause) (gives w)}"

proc finding*(cx: Cx, resolve: Search[Value, Value] = nil) =
  ## a find done here answers what it finds: of the subjects it holds,
  ## and of those it names, found through `resolve`
  cx.install(initRec(@[sym"kind", sym"find"]), Finding(resolve: resolve))

# ================ sends and searches ================

let
  PutQ = sym"put"
  AskQ = sym"ask"
  Taken = sym"taken"

type
  Put = ref object of Doer
    to: Send[Value, Value]
  Ask = ref object of Doer
    space: Search[Value, Value]

method fits(d: Put, v: Value): bool =
  v.isKind(bRec) and v.items.len == 3

method answers(d: Put, v: Value, cx: Cx): Stream[Value] =
  ## `taken` once the send takes (Q A): that it was done, so it is never
  ## passed on to another; nothing if it wasn't taken
  let (q, a, to) = (v.items[1], v.items[2], d.to)
  lazy(() => (block:
    if to.send(q, a):
      cx.acted
      just(Taken)
    else: empty(Value)))

method describe(d: Put): Value = rv"!(put Q A)"

method fits(d: Ask, v: Value): bool =
  v.isKind(bRec) and v.items.len == 2

method answers(d: Ask, v: Value, cx: Cx): Stream[Value] =
  d.space[v.items[1]]

method describe(d: Ask): Value = rv"!(ask Q)"

proc install*(cx: Cx, to: Send[Value, Value]) =
  ## !(put Q A) tells `to`
  cx.install(PutQ, Put(to: to))

proc install*(cx: Cx, space: Search[Value, Value]) =
  ## !(ask Q) answers what `space` answers
  cx.install(AskQ, Ask(space: space))

# ================ the vocabulary ================

proc base*(unheard: (Value) -> void = nil,
           refused: (ref BasslineError) -> void = nil): Cx =
  ## a cx holding the base vocabulary
  result = newCx(unheard, refused)
  result.install(native Do, native If, native Else, native Then, native Case, native Quote,
    native All, native First, native Count, native Take, native In,
    native Let, native Add, native Sub, native Mul, native Div, native Mod,
    native Sum, native Lt, native Le, native Gt, native Ge, native Eq,
    native Ne, native Compare, native Range, native Len, native Has, native Lacks, native Get,
    native Fill, native Inject, native Describe, native Readings)
  let r = Reduce()
  for k in [bList, bDict, bSet]:
    result.install(initRec(@[sym"frame", sym($k)]), r)
  result.install(FnQ, Fn())
  result.install(RecordQ, Make())
  result.finding