## Queries: streams over values, and what objects answer.
##
## Simple streams to compose from: a frame's `parts`, everything inside a
## value (`walk`), a set's `members`, a dict's `entries`, and a set's
## members between bounds (`between`), such as its lists or records that
## begin with given members (`ledBy`) or its records under a head
## (`headed`), found by bisecting. Predicates over values (`isKind`,
## `hasWidth`, `isObject`, `prefixes`, `similar`) are plain functions,
## value first, used through `x => …` lambdas with `filter` and the rest,
## or through the `it` forms, and `unique` passes each value once. `map`
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

refuseWith BasslineError

# to: where a send sends, !(to ID), marked
blet"{to search-space}"
# partsQ: a composite's parts, in order
# holdsQ: what a space holds
# sendQ: a bvar's send
# searchQ: a bvar's search
# kindQ: how to bring a thing about, !(kind K), marked
blet"""{identity-q: identity parts-q: parts holds-q: holds send-q: send
  search-q: search kind-q: kind ranked-kind: ranked cat-kind: cat alt-kind: alt
  feed-kind: feed merge-kind: merge more-kind: more via-kind: via send-kind: send
  b-var-kind: bvar}"""

# ================ predicates and maps over values ================

func hasWidth*(v: Value, n: int): bool =
  v.isKind({bList, bRec}) and v.items.len == n

func isObject*(v: Value): bool =
  v.isKind(bSet, marked)

func always*(v: Value): bool = true

func sameFamily*(a, b: SomeValue): bool =
  a.isKind(b.kind, some b.mark)

func prefixes*(a, b: Value): bool =
  ## Whether `a` is a prefix of `b`: what `b`'s canonical encoding
  ## yields when stopped early, with every frame the stop left open
  ## closed by END. Reflexive. Kind and mark must agree. Among scalars
  ## only equal values are prefixes, since a scalar carries its own
  ## length. In a frame every member but the last must equal `b`'s,
  ## and the last is itself a prefix of `b`'s, since a truncation only
  ## drops a suffix. Dicts and sets compare in canonical order, so a
  ## prefix is a leading run of the sorted members, not a subset.
  if not a.sameFamily(b):
    return false
  case a.kind
  of bNil, bNum, bText, bSym, bBytes:
    return a == b
  of bList, bRec:
    let n = a.items.len
    if n > b.items.len:
      return false
    for i, x, y in lockstep(a.items, b.items):
      if i + 1 == n:
        if not x.prefixes(y): return false
      elif x != y:
        return false
  of bDict:
    let n = a.dict.len
    if n > b.dict.len:
      return false
    var i = 0
    for x, y in lockstep(a.dict, b.dict):
      if i + 1 == n:
        if x.key != y.key or not x.val.prefixes(y.val): return false
      elif x.key != y.key or x.val != y.val:
        return false
      inc i
  of bSet:
    let n = a.els.len
    if n > b.els.len:
      return false
    var i = 0
    for x, y in lockstep(a.els, b.els):
      if i + 1 == n:
        if not x.prefixes(y): return false
      elif x != y:
        return false
      inc i
  true

type
  Answer* = object
    question*: Value
    answer*: Value

proc toAnswer*(v: Value): Option[Answer] =
  matchValue v:
  of "($question $answer) {any-mark}": some Answer(question: question, answer: answer)
  else: none Answer

# ================ streams over values ================

proc strictlyAfter(last: Value): (Value) -> bool =
  (it: Value) => it > last

proc between*(space: BSet, atOrAfter, upTo: (Value) -> bool): Stream[Value] =
  ## a set's members from the first `atOrAfter` holds for to the last
  ## `upTo` holds for, in CE order. Each pull bisects afresh to the first
  ## after the last one given, so the stream holds a value, not a place
  ## in the set: the set may grow between pulls, and what grows past that
  ## value is seen
  var last = none(Value)
  proc pull(): Option[Value] =
    let after = if last.isNone: atOrAfter else: strictlyAfter(last.get)
    for m in space.itemsFrom(after, upTo):
      last = some(m)
      return last
    none(Value)
  pull

func against*(m: Value, kind: Kind, lead: seq[Value], marked: bool): int =
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
  space.between(it => against(it, kind, lead, marked) >= 0,
                it => against(it, kind, lead, marked) <= 0)

proc headed*(space: BSet, head: Value, marked = false): Stream[Value] =
  ## a set's records headed by `head`, unmarked or marked, in CE order
  space.ledBy(bRec, @[head], marked)

proc members*(v: Value): Stream[Value] =
  ## a set's members, in CE order; nothing for anything else
  if not v.isKind(bSet): return empty Value
  v.els.between(always, always)

proc entries*(v: Value): Stream[(Value, Value)] =
  ## a dict's entries, key and value, in CE order of the keys, each pull
  ## bisecting afresh past the last key given; nothing for anything else
  if not v.isKind(bDict): return empty((Value, Value))
  let d = v.dict
  var last = none(Value)
  proc pull(): Option[(Value, Value)] =
    let after = if last.isNone: always else: strictlyAfter(last.get)
    for k, x in d.pairsFrom(after, always):
      last = some(k)
      return some((k, x))
    none((Value, Value))
  pull

proc parts*(v: Value): Stream[Value] =
  ## a frame's members: a list's or record's in order, a dict's keys and
  ## values, a set's members; nothing for an atom
  case v.kind
  of bList, bRec: initStream v.items.data
  of bDict: v.entries.flatMaps initStream(@[it[0], it[1]])
  of bSet: v.members
  else: empty Value

proc walk*(v: Value): Stream[Value] =
  ## `v`, then everything inside it, depth first: a record's head before
  ## its fields, a dict's key before its value
  just(v) & v.parts.flatMaps(walk it)

proc unique*(s: Stream[Value]): Stream[Value] =
  ## `s`, each value once
  var seen = initSet()
  s.filters:
    if it in seen.els: false
    else:
      seen.incl it
      true

proc similar*(v, exemplar: Value): bool =
  ## whether `v` looks like `exemplar` by kind and mark all the way down:
  ## an atom of the same kind and mark; a list or record with at least
  ## the exemplar's members, each leading one similar to the exemplar's in
  ## its place (a record's head equal to it); a dict with each of the
  ## exemplar's keys, its value similar; a set with every member of the
  ## exemplar's
  if not v.sameFamily(exemplar):
    return false
  case exemplar.kind
  of bList, bRec:
    if v.items.len < exemplar.items.len: return false
    for i in 0 ..< exemplar.items.len:
      let (a, b) = (v.items[i], exemplar.items[i])
      if not (if i == 0 and v.isKind(bRec): a == b else: a.similar(b)):
        return false
    true
  of bDict:
    exemplar.entries.every(e => e[0] in v.dict and v.dict[e[0]].similar(e[1]))
  of bSet: exemplar.els <= v.els
  else: true

# ================ making values over ================

proc map*(v: Value, fn: (Value) -> Value): Value =
  ## `v` with each of its parts made over by `fn`, a dict's keys as well
  ## as its values, its mark kept. Refuses an atom, which has no parts
  case v.kind
  of bList: initList(v.items.map(fn), v.mark)
  of bRec: initRec(v.items.map(fn), v.mark)
  of bDict: initDict(v.dict.map((k, x: Value) -> Pair[Value] => (fn k, fn x)), v.mark)
  of bSet: initSet(v.els.map(fn), v.mark)
  else: refuse "an atom has no parts to map: " & $v

# ================ what objects answer ================

proc obj*(members: varargs[Value]): Value =
  ## an object of these members: answers and orders
  initSet(members, mark = true)

proc under(o: Value, question: Value, marked: bool): Stream[Value] =
  ## the second fields of an object's records headed by `question`,
  ## unmarked or marked, in CE order; nothing for a value that isn't an
  ## object
  if not o.isObject: return empty Value
  o.els.headed(question, marked).filterMap(toAnswer).maps(it.answer)

proc answers*(o: Value, question: Value): Stream[Value] =
  ## what an object answers to `question`, in CE order
  o.under(question, marked = false)

proc answer*(o: Value, question: Value): Option[Value] =
  ## an answer an object gives to `question`, for a consumer that wants
  ## one: the first, in CE order
  o.answers(question).next

proc orders*(o: Value, question: Value): Stream[Value] =
  ## an object's orders under `question`, !(QUESTION ANSWER), in CE order
  o.under(question, marked = true)

proc order*(question, answer: Value): Value =
  ## !(QUESTION ANSWER): an order, not just something answered
  initRec(@[question, answer], mark = true)

proc target*(id: Value): Value =
  ## !(to ID): an order to send to the thing going by `id`
  order(to, id)

proc targets*(o: Value): Stream[Value] =
  ## the IDs an object's !(to ID) orders send to
  o.orders to

proc kinds*(o: Value): Stream[Value] =
  ## an object's kinds, from its !(kind K) orders
  o.orders kindQ

proc hasKind*(o: Value, kind: Value): bool =
  ## whether an object has this kind among its kinds
  o.isObject and order(kindQ, kind) in o.els

# ================ names ================

proc identities*(id: Value): Stream[Value] =
  ## the names an ID goes by: an object's answers to `identity`, or a
  ## value that isn't an object, alone
  if id.isObject: id.answers identityQ else: just id

proc knownAs*(id: Value, name: Value): bool =
  ## whether an ID goes by `name`
  if id.isObject: initRec(@[identityQ, name]) in id.els else: id == name

proc sharesIdentity*(a, b: Value): bool =
  ## whether two IDs speak of the same thing: a name of one is a name of
  ## the other
  a.identities.exists(id => b.knownAs id)

proc identityAnswers(id: Value): Stream[Value] =
  ## the (identity NAME) records an ID stands for, to put in an object
  id.identities.maps initRec(@[identityQ, it])

proc identity*(names: varargs[Value]): Value =
  ## an object that is only names: one (identity NAME) per name, an
  ## object among them giving its own
  initStream(@names).flatMaps(identityAnswers it).toSeq.obj

proc identityOf*(v: Value): Value =
  ## the names alone of a thing: an object's identity answers as an
  ## object, or a value that isn't an object, itself
  if v.isObject: v.identityAnswers.toSeq.obj else: v

proc randomId*(): Value =
  ## an identity of sixteen random bytes, for a thing nobody else has
  ## named
  identity bytes(urandom 16)

proc alsoKnownAs*(o: Value, more: varargs[Value]): Value =
  ## `o` with more names, everything else it answers kept
  let own = if o.isObject: o.members else: o.identityAnswers
  (own & initStream(@more).flatMaps(identityAnswers it)).toSeq.obj

proc describe*(ks: openArray[Value], id: Value, more: varargs[Value]): Value =
  ## an object of these kinds, going by `id`'s names, answering `more`
  (initStream(@ks).maps(order(kindQ, it)) & id.identityAnswers & initStream(@more)).toSeq.obj
