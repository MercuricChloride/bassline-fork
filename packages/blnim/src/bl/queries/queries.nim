## Queries: streams over values, and what objects answer.
##
## Simple streams to compose from: a frame's `parts`, everything inside a
## value (`walk`), a set's `members`, a dict's `entries`, and a set's
## members between bounds (`between`), such as its lists or records that
## begin with given members (`ledBy`) or its records under a head
## (`headed`), found by bisecting. Predicates over values (`isKind`,
## `isMarked`, `hasWidth`, `isObject`, `prefixes`, `similar`) are plain
## functions, value first, used through `Value -> …` lambdas with `|>`,
## `filter` and the rest, and `unique` passes each value once. `map`
## makes a frame over, part by part.
##
## An object is a marked set: the mark says it is a thing to bring about
## here, not just data. Its members are records shaped as answers: an
## unmarked (QUESTION ANSWER) is something it answers, and a marked
## !(QUESTION ANSWER) is an order, such as its kinds, !(kind K), which
## together say how to bring it about (a search space that is a cat is
## both), or a send's !(to ID).
##
##   !{!(kind search-space) (identity s1) (holds {(alice 1)})}
##   !{!(kind search-space) !(kind cat) (identity s) (parts [PART …])}
##   !{(identity p1) (identity 0x9f3a…) (address "10.0.0.1")}
##
## So what an object answers is a query over its members: its records
## under a head, of width two, and their one field. Every kind of every
## object is found the way any answer is. An object with no kinds is a
## description to find a thing by. What it is called is its answers to
## `identity`, one per name; two things are the same for a reader when
## a name of one is a name of the other, and learning more about a thing
## is a union. A value that isn't an object is a name of its own.

import std/[options, sysrand]
import ../core
import ./stream
export stream

refuseWith ValueError

let
  IdentityQ* = sym"identity"
  PartsQ* = sym"parts"     ## a composite's parts, in order
  HoldsQ* = sym"holds"     ## what a space holds
  SendQ* = sym"send"       ## a bvar's send
  SearchQ* = sym"search"   ## a bvar's search
  KindQ* = sym"kind"       ## how to bring a thing about: !(kind K), marked
  ToQ* = sym"to"           ## where a send sends: !(to ID), marked
  SearchSpaceKind* = sym"search-space"
  RankedKind* = sym"ranked"
  CatKind* = sym"cat"
  AltKind* = sym"alt"
  FeedKind* = sym"feed"
  MergeKind* = sym"merge"
  SendKind* = sym"send"
  BVarKind* = sym"bvar"

# ================ predicates and maps over values ================

func isKind*(v: Value, kinds: set[Kind]): bool =
  v.kind in kinds

func isMarked*(v: Value): bool = v.mark

func hasWidth*(v: Value, n: int): bool =
  v.isKind({bList, bRec}) and v.items.len == n

func isObject*(v: Value): bool =
  v.isKind({bSet}) and v.isMarked

func always*(v: Value): bool = true

func family*(v: SomeValue): tuple[kind: Kind, mark: bool] =
  ## a value's kind and mark, which a value and what it fits share
  (v.kind, v.mark)

func prefixes*(a, b: Value): bool =
  ## Whether `a` is a prefix of `b`: what `b`'s canonical encoding
  ## yields when stopped early, with every frame the stop left open
  ## closed by END. Reflexive. Kind and mark must agree. Among scalars
  ## only equal values are prefixes, since a scalar carries its own
  ## length. In a frame every member but the last must equal `b`'s,
  ## and the last is itself a prefix of `b`'s, since a truncation only
  ## drops a suffix. Dicts and sets compare in canonical order, so a
  ## prefix is a leading run of the sorted members, not a subset.
  ensure a.family == b.family

  case a.kind
  of bNil, bNum, bText, bSym, bBytes:
    ensure a == b
  of bList, bRec:
    let n = a.items.len
    ensure n <= b.items.len
    for i, x, y in lockstep(a.items, b.items):
      if i + 1 == n:
        ensure x.prefixes(y)
      else:
        ensure x == y
  of bDict:
    let n = a.dict.len
    ensure n <= b.dict.len
    var i = 0
    for x, y in lockstep(a.dict, b.dict):
      if i + 1 == n:
        ensure x.key == y.key and x.val.prefixes(y.val)
      else:
        ensure x.key == y.key and x.val == y.val
      inc i
  of bSet:
    let n = a.els.len
    ensure n <= b.els.len
    var i = 0
    for x, y in lockstep(a.els, b.els):
      if i + 1 == n:
        ensure x.prefixes(y)
      else:
        ensure x == y
      inc i
  return true

type
  Answer* = object
    question*: Value
    answer*: Value

proc toAnswer*(v: Value): Option[Answer] =
  if v.kind == bRec and v.hasWidth(2):
    some Answer(question: v.items[0], 
                answer: v.items[1])
  else: none Answer

# ================ streams over values ================

proc strictlyAfter(last: Value): Pred[Value] =
  Value -> it > last

proc between*(space: BSet, atOrAfter, upTo: Pred[Value]): Stream[Value] =
  ## a set's members from the first `atOrAfter` holds for to the last
  ## `upTo` holds for, in CE order. Each pull bisects afresh to the first
  ## after the last one given, so the stream holds a value, not a place
  ## in the set: the set may grow between pulls, and what grows past that
  ## value is seen
  var last = none(Value)
  proc(): Option[Value] =
    let after = if last.isNone: atOrAfter else: strictlyAfter(last.get)
    for m in space.itemsFrom(after, upTo):
      last = some m
      return last
    none(Value)

func against(m: Value, kind: Kind, lead: seq[Value], marked: bool): int =
  ## where `m` sorts against the lists or records of `kind`, unmarked or
  ## marked, that begin with `lead`: before them (< 0), among them (0), or
  ## after them (> 0). CE order sorts by kind, then mark, then member by
  ## member, and a frame that runs out first sorts after those it begins
  if m.kind != kind: return cmp(m.kind, kind)
  if m.mark != marked: return cmp(m.mark, marked)
  for i, x in lead:
    if i == m.items.len: return 1
    let c = cmp(m.items[i], x)
    if c != 0: return c
  0

proc ledBy*(space: BSet, kind: Kind, lead: seq[Value], marked = false):
    Stream[Value] =
  ## a set's lists or records (`kind`), unmarked or marked, that begin
  ## with the members `lead`, in CE order: one run, found by bisecting
  space.between(Value -> against(it, kind, lead, marked) >= 0,
                Value -> against(it, kind, lead, marked) <= 0)

proc headed*(space: BSet, head: Value, marked = false): Stream[Value] =
  ## a set's records headed by `head`, unmarked or marked, in CE order
  space.ledBy(bRec, @[head], marked)

proc members*(v: Value): Stream[Value] =
  ## a set's members, in CE order; nothing for anything else
  if v.kind != bSet: return empty[Value]()
  v.els.between(always, always)

proc entries*(v: Value): Stream[(Value, Value)] =
  ## a dict's entries, key and value, in CE order of the keys, each pull
  ## bisecting afresh past the last key given; nothing for anything else
  if v.kind != bDict: return empty[(Value, Value)]()
  let d = v.dict
  var last = none(Value)
  proc(): Option[(Value, Value)] =
    let after = if last.isNone: always else: strictlyAfter(last.get)
    for k, x in d.pairsFrom(after, always):
      last = some k
      return some (k, x)
    none((Value, Value))

proc parts*(v: Value): Stream[Value] =
  ## a frame's members: a list's or record's in order, a dict's keys and
  ## values, a set's members; nothing for an atom
  case v.kind
  of bList, bRec: initStream(v.items.data)
  of bDict: v.entries.flatMap((Value, Value) -> initStream(@[it[0], it[1]]))
  of bSet: v.members
  else: empty[Value]()

proc walk*(v: Value): Stream[Value] =
  ## `v`, then everything inside it, depth first: a record's head before
  ## its fields, a dict's key before its value
  cat(just(v), v.parts.flatMap(Value -> walk(it)))

proc unique*(s: Stream[Value]): Stream[Value] =
  ## `s`, each value once
  let seen = newBSet()
  s.filter(proc(v: Value): bool =
    result = v notin seen
    if result: seen.incl v)

proc similar*(v, exemplar: Value): bool =
  ## whether `v` looks like `exemplar` by kind and mark all the way down:
  ## an atom of the same kind and mark; a list or record with at least
  ## the exemplar's members, each leading one similar to the exemplar's in
  ## its place (a record's head equal to it); a dict with each of the
  ## exemplar's keys, its value similar; a set with every member of the
  ## exemplar's
  if v.family != exemplar.family: return false
  case exemplar.kind
  of bList, bRec:
    if v.items.len < exemplar.items.len: return false
    for i in 0 ..< exemplar.items.len:
      let (a, b) = (v.items[i], exemplar.items[i])
      if not (if i == 0 and v.kind == bRec: a == b else: a.similar(b)):
        return false
    true
  of bDict:
    exemplar.entries.every((Value, Value) ->
      it[0] in v.dict and v.dict[it[0]].similar(it[1]))
  of bSet: exemplar.els <= v.els
  else: true

# ================ making values over ================

proc map*(v: Value, fn: proc(v: Value): Value): Value =
  ## `v` with each of its parts made over by `fn`, a dict's keys as well
  ## as its values, its mark kept. Refuses an atom, which has no parts
  case v.kind
  of bList: initList(v.items.map(fn), v.mark)
  of bRec: initRec(v.items.map(fn), v.mark)
  of bDict: initDict(v.dict.map(proc(k, x: Value): Pair[Value] = (fn(k), fn(x))), v.mark)
  of bSet: initSet(v.els.map(fn), v.mark)
  else: refuse "an atom has no parts to map: " & $v

# ================ what objects answer ================

proc obj*(members: varargs[Value]): Value =
  ## an object of these members: answers and orders
  initSet(toBTreeSet(members), mark = true)

proc under(o: Value, question: Value, marked: bool): Stream[Value] =
  ## the second fields of an object's records headed by `question`,
  ## unmarked or marked, in CE order; nothing for a value that isn't an
  ## object
  if not o.isObject: return empty[Value]()
  o.els.headed(question, marked).filterMap(toAnswer).map(Answer -> it.answer)

proc answers*(o: Value, question: Value): Stream[Value] =
  ## what an object answers to `question`, in CE order
  o.under(question, marked = false)

proc answer*(o: Value, question: Value): Option[Value] =
  ## an answer an object gives to `question`, for a consumer that wants
  ## one: the first, in CE order
  o.answers(question)[]

proc orders*(o: Value, question: Value): Stream[Value] =
  ## an object's orders under `question`, !(QUESTION ANSWER), in CE order
  o.under(question, marked = true)

proc order*(question, answer: Value): Value =
  ## !(QUESTION ANSWER): an order, not just something answered
  initRec(@[question, answer], mark = true)

proc target*(id: Value): Value =
  ## !(to ID): an order to send to the thing going by `id`
  order(ToQ, id)

proc targets*(o: Value): Stream[Value] =
  ## the IDs an object's !(to ID) orders send to
  o.orders(ToQ)

proc kinds*(o: Value): Stream[Value] =
  ## an object's kinds, from its !(kind K) orders
  o.orders(KindQ)

proc hasKind*(o: Value, kind: Value): bool =
  ## whether an object has this kind among its kinds
  o.isObject and order(KindQ, kind) in o.els

# ================ names ================

proc identities*(id: Value): Stream[Value] =
  ## the names an ID goes by: an object's answers to `identity`, or a
  ## value that isn't an object, alone
  if id.isObject: id.answers(IdentityQ) else: just(id)

proc knownAs*(id: Value, name: Value): bool =
  ## whether an ID goes by `name`
  if id.isObject: initRec(@[IdentityQ, name]) in id.els else: id == name

proc sharesIdentity*(a, b: Value): bool =
  ## whether two IDs speak of the same thing: a name of one is a name of
  ## the other
  identities(a).exists(proc(id: Value): bool = b.knownAs(id))

proc identityAnswers(id: Value): Stream[Value] =
  ## the (identity NAME) records an ID stands for, to put in an object
  identities(id).map(Value -> initRec(@[IdentityQ, it]))

proc identity*(names: varargs[Value]): Value =
  ## an object that is only names: one (identity NAME) per name, an
  ## object among them giving its own
  obj(collect(initStream(@names).flatMap(Value -> identityAnswers(it))))

proc identityOf*(v: Value): Value =
  ## the names alone of a thing: an object's identity answers as an
  ## object, or a value that isn't an object, itself
  if v.isObject: obj(collect(identityAnswers(v))) else: v

proc randomId*(): Value =
  ## an identity of sixteen random bytes, for a thing nobody else has
  ## named
  identity(bytes(urandom(16)))

proc alsoKnownAs*(o: Value, more: varargs[Value]): Value =
  ## `o` with more names, everything else it answers kept
  obj(collect(cat(if o.isObject: o.members else: identityAnswers(o),
                initStream(@more).flatMap(Value -> identityAnswers(it)))))

proc describe*(ks: openArray[Value], id: Value, more: varargs[Value]): Value =
  ## an object of these kinds, going by `id`'s names, answering `more`
  obj(collect(cat(initStream(@ks).map(Value -> order(KindQ, it)),
                identityAnswers(id), initStream(@more))))
