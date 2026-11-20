## Finds: queries written down as search spaces, and what they find.
##
## A find is an object, one more kind of search space:
##
##   !{!(kind search-space) !(kind find) (identity ID)
##     (of SUBJECT) …       what it asks of
##     (hole H) …           parts of its clauses that stand for what is there
##     (asked H) …          holes bound to whatever the find is asked
##     (where CLAUSE) …     what must be found, each clause a shape's example
##     (gives W) …}         each answer: W, its holes filled in
##
## A subject is a search space (held, composite, or another find), an
## object, whose records are what it answers, or names of one, found when
## the find is asked. Several subjects take turns. What a subject value
## stands for is read where searches are (`bl/queries/search`), as
## `fromValue` reads a space, refusing what it refuses unless the asker
## passes over refusals; here a subject is what it answers, headed by a
## question or all it can say it holds.
##
## Each clause is fitted against a subject's records, as a shape is: holes
## bound under which a record fits it. A clause whose question (its record's
## head) is settled by the bindings so far asks for that question's records
## alone, found by bisecting; any other looks at every record a subject can
## say it holds, which a search running here can't. Clauses are a set: which
## goes next is chosen as the bindings grow, those that only check first,
## then those whose question is settled, then the rest. Each clause is a
## search from bindings to their extensions, and the find feeds the bindings
## through them. A record (Q R A) of a ranked space fits a clause (Q A), its
## rank passed over, and a clause of three fields as it is; a hole or form
## that takes the whole record takes it as held, rank and all.
##
## A clause that only checks, holding no hole the bindings leave open, is
## asked for one answer, or under `why` one for each part that answers it. What each binding leads to takes turns with the
## rest, so a subject that never runs out starves none of them.
##
## A find answers each binding found once, written as each of its gives
## whose holes the binding binds, or, giving nothing, as the bindings
## themselves. A gives may hold a find, its own holes left alone: it asks of
## the outer find's subjects, as written, when it says nothing to ask of,
## and each of its names goes with the bindings it was filled from, so each
## filling is a thing of its own. An answer can carry a further question to
## ask when wanted. Further kinds add to it: `distinct` answers each answer
## once, `count` answers how many it has found so far as each is found, and
## `why` answers (why ANSWER {PART …}), the parts whose records answered,
## once for each set of parts that answers it.
##
## Within a clause a few marked records are read as forms, never looked up
## as written: !(within P) fits a value with something fitting P anywhere in
## it, itself included; !(any P …) fits what fits any of them; !(all P …)
## what fits every one; !(as H P) what fits P, binding the hole H to it
## whatever its mark, and !(as H) anything, so bound; and !(quote V) is V
## as written.


import std/[algorithm, options, sequtils]
import ../core
import ./[queries, stream, rewrite]
export rewrite

refuseWith BasslineError

blet"{why hole where within quote}"
# ofQ: what a find asks of
blet"""{find-kind: find distinct-kind: distinct count-kind: count of-q: of
  asked-q: asked gives-q: gives any-form: any all-form: all as-form: as}"""

type
  Find* = object
    ## a find, read
    subjects*: seq[Value]  ## what it asks of, its (of …) answers
    holes*: BSet
    asked*: seq[Value]     ## holes bound to what the find is asked
    wheres*: seq[Value]
    gives*: seq[Value]
    once*: bool            ## !(kind distinct): each answer once
    counting*: bool        ## !(kind count)
    sayingWhy*: bool       ## !(kind why)

  Because* = object
    ## which part answered a clause, and with which record, as held
    clause*, part*, record*: Value

  Row* = object
    ## one answer of a find, the bindings it was written from, and which
    ## part answered each clause
    answer*, bindings*: Value
    why*: seq[Because]

  Hit* = object
    ## a record a subject holds, the part holding it, and whether it is
    ## ranked, (Q R A)
    record*, part*: Value
    ranked*: bool

  Led* = object
    ## a list or record (`kind`) of `mark` beginning with `lead`
    kind*: Kind
    lead*: seq[Value]
    mark*: bool

  Question* = object
    ## what a clause asks a subject for: its records, marked or not, whose
    ## head is `exact`, or else `led`. `value`, when there is one, is the
    ## one head a search running here can be asked about; what it answers
    ## fits, and is all it can say
    marked*: bool
    exact*: Option[Value]
    led*: Option[Led]
    value*: Option[Value]

  Subject* = object
    ## something a find asks of: its records answering any of several
    ## questions, in rank order when it is ranked and otherwise taking turns,
    ## and every record it can say it holds
    headed*: (seq[Question]) -> Stream[Hit]
    all*: () -> Stream[Hit]

proc isFind*(v: Value): bool =
  v.hasKind(searchSpace) and v.hasKind(findKind)

proc isForm*(p: Value): bool =
  ## whether `p` is read as a form in a clause
  p.isKind(bRec, marked) and p.head in [within, anyForm, allForm, asForm, quote]

proc isFrame(v: Value): bool =
  v.isKind({bList, bRec, bDict, bSet})

# ================ reading ================

proc checkForms(c: Value, holes: BSet) =
  ## the forms in a clause, checked: each says what it needs. Nothing under a
  ## quote is a form, nor anything in a hole
  if c in holes: return
  if isForm(c):
    let n = c.items.len - 1
    if c.head == quote:
      guard n == 1, "!(quote V) quotes one value: " & $c
      return
    guard c.head != within or n == 1,
      "!(within P) has one part to look for: " & $c
    guard c.head != asForm or (n in 1..2 and c.items[1] in holes),
      "!(as H P) binds a hole H, to what fits P if it says one: " & $c
    guard n > 0, "!(any …) and !(all …) need a part: " & $c
  if c.isFrame:
    for p in c.parts: checkForms(p, holes)

proc fromValue*(T: typedesc[Find], v: Value): Find =
  ## a find, read. Refuses a value that isn't one, a kind it doesn't read,
  ## counting together with saying why, an asked hole that isn't a hole, and
  ## a form without what it needs
  guard isFind(v), "not a find: " & $v
  let readable = [searchSpace, findKind, distinctKind, countKind, why]
  let unread = v.kinds.filters(it notin readable).next
  guard unread.isNone, "a kind a find doesn't read, " & $unread.get & ", in " & $v
  result = Find(
    subjects: v.answers(ofQ).toSeq,
    holes: toBSet(v.answers(hole)),
    asked: v.answers(askedQ).toSeq,
    wheres: v.answers(where).toSeq,
    gives: v.answers(givesQ).toSeq,
    once: v.hasKind(distinctKind),
    counting: v.hasKind(countKind),
    sayingWhy: v.hasKind(why))
  for h in result.asked:
    guard h in result.holes, "asked binds a hole: " & $h
  for c in result.wheres: checkForms(c, result.holes)
  guard not (result.counting and result.sayingWhy),
    "a count has no parts to say why: " & $v

proc find*(subjects: openArray[Value] = []; holes: openArray[Value] = [];
           asked: openArray[Value] = []; wheres: openArray[Value] = [];
           gives: openArray[Value] = []; kinds: openArray[Value] = [];
           id = randomId()): Value =
  ## a find written down, an object of its kinds going by `id`
  var more: seq[Value]
  for (q, xs) in [(ofQ, @subjects), (hole, @holes), (askedQ, @asked),
                  (where, @wheres), (givesQ, @gives)]:
    for x in xs: more.add initRec(@[q, x])
  describe(@[searchSpace, findKind] & @kinds, id, more)

# ================ subjects ================

proc rankOrder(a, b: Hit): int = cmp(a.record.items[1], b.record.items[1])

proc natural(v: Value): bool =
  ## a natural, of any size
  v.isKind(bNum, unmarked) and v.num >= 0

proc ledHeads(space: BSet, marked: bool, led: Led): Stream[Value] =
  ## a set's records, marked or not, whose head is led as `led` says, found
  ## by bisecting
  proc pos(m: Value): int =
    if not m.isKind(bRec): return cmp(m.kind, bRec)
    if m.mark != marked: return cmp(m.mark, marked)
    against(m.items[0], led.kind, led.lead, led.mark)
  space.between(it => pos(it) >= 0, it => pos(it) <= 0)

proc recordsFor(space: BSet, q: Question): Stream[Value] =
  ## a set's records answering `q`: headed exactly, or led
  if q.exact.isSome: space.ledBy(bRec, @[q.exact.get], q.marked)
  else: ledHeads(space, q.marked, q.led.get)

proc unmarkedOnly(qs: seq[Question]): seq[Question] =
  collect(for q in qs: (if not q.marked: q))

proc held*(d: Value, bodies: seq[Value], ranked, skipRefused: bool): Subject =
  ## a space holding its answers itself in `bodies`, each a set of records
  ## or, unranked, a dict. A question, (Q) alone, is passed over; any other
  ## record that isn't (Q A), or (Q R A) with R a natural when ranked, is
  ## refused unless refusals are passed over
  let part = identityOf d
  proc holds(r: Value): bool =
    matchValue r:
    of "($_) {any-mark}": return false  # a question, not an answer
    of "($_ $_)": result = not ranked
    of "($_ $rank $_)": result = ranked and natural(rank)
    else: discard
    if not result and not skipRefused:
      refuse "not a (query " & (if ranked: "rank " else: "") & "answer) record: " & $r
  proc hit(r: Value): Hit = Hit(record: r, part: part, ranked: ranked)
  proc bodyHits(b: Value, q: Option[Question]): Stream[Hit] =
    if b.isKind(bDict):
      if q.isSome and q.get.exact.isSome:
        let head = q.get.exact.get
        if head notin b.dict: return empty Hit
        return just hit(initRec(@[head, b.dict[head]]))
      return b.entries
        .filters(q.isNone or against(it[0], q.get.led.get.kind, q.get.led.get.lead,
                                     q.get.led.get.mark) == 0)
        .maps(hit(initRec(@[it[0], it[1]])))
    if q.isSome: return recordsFor(b.els, q.get).filters(holds(it)).maps(hit(it))
    if not ranked: return b.members.filters(holds(it)).maps(hit(it))
    # all of a ranked body, in rank order
    lazy(() => initStream(b.members.filters(holds(it)).maps(hit(it)).toSeq.sorted(rankOrder)))
  proc bodiesFor(q: Option[Question]): seq[Stream[Hit]] =
    initStream(bodies).maps(bodyHits(it, q)).toSeq
  proc join(qs: seq[Option[Question]]): Stream[Hit] =
    var each: seq[Stream[Hit]]
    for q in qs:
      let streams = bodiesFor(q)
      if ranked: each.add streams else: each.add cat(streams)
    if ranked: merge(rankOrder, each) else: alt(each)
  Subject(headed: (qs: seq[Question]) => join(initStream(qs.unmarkedOnly).maps(some(it)).toSeq),
          all: () => join(@[none Question]))

proc thing*(d: Value): Subject =
  ## an object that isn't a search space: what it answers, (Q A), and its
  ## orders, !(Q A)
  let part = identityOf d
  proc hit(r: Value): Hit = Hit(record: r, part: part)
  Subject(headed: (qs: seq[Question]) =>
            alt(initStream(qs).maps(recordsFor(d.els, it).filters(it.items.len == 2).maps(hit(it))).toSeq),
          all: () => d.members.filters(it.isKind(bRec) and it.items.len == 2).maps(hit(it)))

proc answering*(ask: (Value) -> Stream[Value], part: Value): Subject =
  ## a search, going by `part`, which answers what it is asked and can't say
  ## what it holds
  proc headed(qs: seq[Question]): Stream[Hit] =
    alt initStream(qs).maps(block:
      let q = it
      let head = if q.exact.isSome: q.exact else: q.value
      if q.marked or head.isNone: empty Hit
      else: ask(head.get).maps(Hit(record: initRec(@[head.get, it]), part: part))).toSeq
  Subject(headed: headed, all: () => empty(Hit))

proc joined*(kind: Value, parts: seq[Subject]): Subject =
  ## parts joined as a composite of `kind` joins them: one after another for
  ## a cat, merged by rank for a merge, and otherwise taking turns
  proc join(each: (Subject) -> Stream[Hit]): Stream[Hit] =
    if kind == catKind: return catFrom initStream(parts).maps(each(it))
    let streams = initStream(parts).maps(each(it)).toSeq
    if kind == mergeKind: merge(rankOrder, streams) else: alt(streams)
  Subject(headed: (qs: seq[Question]) => join(p => p.headed(qs)),
          all: () => join(p => p.all()))

proc fed*(first, then: Subject): Subject =
  ## each answer of `first` asked of `then`, their records taking turns as
  ## they arrive: (Q A) or (Q R A), as `then` answers A to `first`'s
  ## answer. It can say all it holds when `first` can
  proc through(hits: Stream[Hit]): Stream[Hit] =
    altFrom hits.maps(block:
      let h = it
      then.headed(@[Question(exact: some h.record.items[^1])]).maps(block:
        let r = if it.ranked: @[h.record.items[0], it.record.items[1], it.record.items[2]]
                else: @[h.record.items[0], it.record.items[1]]
        Hit(record: initRec(r), part: it.part, ranked: it.ranked)))
  Subject(headed: (qs: seq[Question]) => through(first.headed(qs.unmarkedOnly)),
          all: () => through(first.all()))

# ================ fitting ================

proc andThen(a, b: Fit): Fit =
  (x: Value) => a(x).flatMap(b)

proc fitForm(part, v: Value, fit: (Value, Value) -> Fit): Fit =
  ## every extension of bindings under which `v` fits the form `part`
  matchValue part:
  of "!(quote $quoted)":
    return (b: Value) => (if quoted == v: just(b) else: empty(Value))
  of "!(any &parts)":
    let fits = initStream(parts).maps(fit(it, v)).toSeq
    return (b: Value) => alt(initStream(fits).maps(it(b)).toSeq)
  of "!(as $hole &inner)":
    return (b: Value) => (block:
      if hole in b.dict and b.dict[hole] != v: return empty(Value)
      var bound = b
      if hole notin b.dict:
        bound = b.copy
        bound[hole] = v
      if inner.len == 0: just(bound) else: fit(inner[0], v)(bound))
  of "!(all &parts)":
    result = fit(parts[0], v)
    for p in parts[1 .. ^1]: result = result.andThen(fit(p, v))
  else:
    let inner = part.items[1]  # within: v or anything in it
    return (b: Value) => walk(v).flatMaps(fit(inner, it)(b)).unique

proc fitsFor(holes: BSet, wild: Value): (Value, Value) -> Fit =
  ## the fits of a find's clauses, the forms read their own way, and `wild`,
  ## a part that fits anything and binds nothing, standing in for the rank a
  ## clause of two fields passes over
  Shape(example: null(), holes: holes, wild: some wild)
    .fitting(Forms(isForm: isForm, fitForm: fitForm))

# ================ finding ================

type
  Pending = object
    b: Value
    why: seq[Because]

  Fitting = object
    ## what a find needs while its clauses are fitted
    holes: BSet
    wild: Value
    fit: (Value, Value) -> Fit
    subjects: seq[Subject]
    why: bool  ## whether the parts that answered are said, so a binding
               ## counts once per part

proc unboundIn(c: Value, holes: BSet, b: Value): int =
  ## how many holes in `c` the bindings leave unbound, each once; none under
  ## a quote
  var open = initSet()
  proc look(p: Value) =
    if p in holes:
      if p notin b.dict: open.incl p
      return
    if isForm(p) and p.head == quote: return
    if p.isFrame:
      for x in p.parts: look(x)
  look c
  open.len

proc exact(v: Value, holes: BSet, b: Value): bool =
  ## whether `v` fits exactly one value, once filled from `b`: an atom, a
  ## hole bound, a quote, an `as` whose hole is bound or whose part is
  ## exact, an `all` with an exact part. A list, record, dict or set fits
  ## more than itself, and is never exact
  if v in holes: return v in b.dict
  if isForm(v):
    matchValue v:
    of "!(quote $_)": return true
    of "!(as $hole)": return hole in b.dict
    of "!(as $hole $part)": return hole in b.dict or exact(part, holes, b)
    of "!(all &parts)": return initStream(parts).exists(a => exact(a, holes, b))
    else: return false
  not v.isFrame

proc settled(v: Value, holes: BSet, b: Value): bool =
  ## whether `v` holds no unbound hole and no form but an exact one: so
  ## filled, it is one value
  if v in holes or isForm(v): return exact(v, holes, b)
  if v.isFrame: return v.parts.every(p => settled(p, holes, b))
  true

proc valueOf(v: Value, holes: BSet, b: Value): Value =
  ## the settled `v` as one value: its holes filled from `b`, its exact
  ## forms what they fit
  if v in holes: return b.dict[v]
  if isForm(v):
    matchValue v:
    of "!(quote $quoted)": return quoted
    of "!(as $hole)": return b.dict[hole]
    of "!(as $hole $part)":
      return if hole in b.dict: b.dict[hole] else: valueOf(part, holes, b)
    of "!(all &parts)":
      for p in parts:
        if exact(p, holes, b): return valueOf(p, holes, b)
    else: discard
  if v.isFrame: return v.map(p => valueOf(p, holes, b))
  v

proc questionIn(w: Value): Option[seq[Question]] =
  ## the questions of the one value `w`: its head exactly if it is a record,
  ## and none if it isn't, since then no record fits
  if w.isKind(bRec): some @[Question(marked: w.mark, exact: some w.head)]
  else: some newSeq[Question]()

proc firstOf(each: seq[Option[seq[Question]]]): Option[seq[Question]] =
  ## the first that is known, an exact one before others
  for qs in each:
    if qs.isSome and qs.get.allIt(it.exact.isSome): return qs
  for qs in each:
    if qs.isSome: return qs

proc unionOf(each: seq[Option[seq[Question]]]): Option[seq[Question]] =
  ## all of them, when each is known: the same exact question once
  var all: seq[Question]
  for qs in each:
    if qs.isNone: return
    for q in qs.get:
      if q.exact.isNone or not all.anyIt(it.exact == q.exact and it.marked == q.marked):
        all.add q
  some all

proc headsOf(p: Value, holes: BSet, b: Value): Option[seq[Question]] =
  ## the heads a clause's head `p` can be under `b`: exactly one value, or a
  ## list or record led by its exact leading members, as a shape's list or
  ## record fits any that begins with its members. None when it could be
  ## anything, a set or dict among them
  if exact(p, holes, b): return some @[Question(exact: some valueOf(p, holes, b))]
  if p in holes: return
  if isForm(p):
    matchValue p:
    of "!(as $_ $part)": return headsOf(part, holes, b)
    of "!(all &parts)": return firstOf initStream(parts).maps(headsOf(it, holes, b)).toSeq
    of "!(any &parts)": return unionOf initStream(parts).maps(headsOf(it, holes, b)).toSeq
    else: return
  if not p.isKind({bList, bRec}): return
  var lead: seq[Value]
  for x in p.items.data:
    if not exact(x, holes, b): break
    lead.add valueOf(x, holes, b)
  var q = Question(led: some Led(kind: p.kind, lead: lead, mark: p.mark))
  if settled(p, holes, b): q.value = some valueOf(p, holes, b)
  some @[q]

proc questionsOf(c: Value, holes: BSet, b: Value): Option[seq[Question]] =
  ## the questions a clause asks under `b`: the records it can fit, by their
  ## heads, each found by bisecting, and none for a clause no record fits.
  ## None at all when they could be any, and every record must be looked at
  if exact(c, holes, b): return questionIn valueOf(c, holes, b)
  if c in holes: return
  if isForm(c):
    matchValue c:
    of "!(as $_ $part)": return questionsOf(part, holes, b)
    of "!(all &parts)": return firstOf initStream(parts).maps(questionsOf(it, holes, b)).toSeq
    of "!(any &parts)": return unionOf initStream(parts).maps(questionsOf(it, holes, b)).toSeq
    else: return
  # an atom, list, dict or set fits no record
  if not c.isKind(bRec): return some newSeq[Question]()
  let heads = headsOf(c.head, holes, b)
  if heads.isNone: return
  var qs = heads.get
  for q in qs.mitems: q.marked = c.mark
  some qs

proc rankless(c, wild: Value, holes: BSet): Value =
  ## the clause `c` as it meets a ranked record (Q R A): a record of two
  ## fields with `wild` in the rank's place, and so the record parts of the
  ## forms that meet the record itself. Holes and forms still meet the
  ## record as held, its rank and all
  if c in holes: return c
  matchValue c:
  of "!(any &parts)":
    let inner = initStream(parts).maps(rankless(it, wild, holes)).toSeq
    bl"!(any @inner)"
  of "!(all &parts)":
    let inner = initStream(parts).maps(rankless(it, wild, holes)).toSeq
    bl"!(all @inner)"
  of "!(as $hole $part)":
    let inner = rankless(part, wild, holes)
    bl"!(as $hole $inner)"
  elif isForm(c): c
  of "($q $a)": bl"($q $wild $a)"
  of "!($q $a)": bl"!($q $wild $a)"
  else: c

proc step(c: Value, p: Pending, x: Fitting): Stream[Pending] =
  ## every extension of `p` under which one of the subjects' records fits the
  ## clause `c`: each once, or once for each part that answers it when the
  ## find says why
  let questions = questionsOf(c, x.holes, p.b)
  let hits = alt initStream(x.subjects).maps(
    if questions.isNone: it.all() else: it.headed(questions.get)).toSeq
  let ranklessly = rankless(c, x.wild, x.holes)
  var given = initSet()
  proc fresh(b, part: Value): bool =
    let key = if x.why: initList(@[b, part]) else: b
    result = key notin given.els
    if result: given.incl key
  proc extensions(hit: Hit): Stream[Pending] =
    x.fit(if hit.ranked: ranklessly else: c, hit.record)(p.b)
      .filter(b => fresh(b, hit.part))
      .maps(Pending(b: it, why: p.why & Because(clause: c, part: hit.part, record: hit.record)))
  hits.flatMap(extensions)

proc through(clauses: seq[Value], p: Pending, x: Fitting): Stream[Pending] =
  ## the clauses fed one into the next, the next chosen each time: one that
  ## only checks, then one whose question is settled, then any other, fewest
  ## holes unbound first. A clause that only checks is asked for one answer,
  ## or one for each part that answers it when the find says why. What each
  ## binding leads to takes turns, so none starves the others
  if clauses.len == 0: return just p
  proc rank(c: Value): (int, int) =
    let open = unboundIn(c, x.holes, p.b)
    if open == 0: (0, 0)
    elif questionsOf(c, x.holes, p.b).isSome: (1, open)
    else: (2, open)
  var best = 0
  for i in 1 ..< clauses.len:
    if rank(clauses[i]) < rank(clauses[best]): best = i
  let c = clauses[best]
  let rest = clauses[0 ..< best] & clauses[best + 1 .. ^1]
  if rank(c)[0] == 0 and not x.why:
    return lazy(() => (block:
      let one = step(c, p, x)()
      if one.isSome: through(rest, one.get, x) else: empty(Pending)))
  altFrom step(c, p, x).maps(through(rest, it, x))

proc needs(w: Value, holes: BSet, into: var Value, kept = newBSet()) =
  ## the holes of `holes` that `w` needs bound to be written: those in it, a
  ## find within it keeping its own, whole, and so `kept`, the holes of finds
  ## it is within
  if w in holes:
    into.incl w
    return
  if w in kept: return
  if w.isKind(bSet) and isFind(w):
    let own = toBSet(w.answers(hole))
    let outer = toBSet(holes.between(always, always).filters(it notin own))
    let keep = kept + own
    for m in w.members: needs(m, outer, into, keep)
    return
  if w.isFrame:
    for p in w.parts: needs(p, holes, into, kept)

proc fill(w, b: Value, holes: BSet, subjects: seq[Value], kept = newBSet()): Value =
  ## `w` with each hole of `holes` filled from `b`, which binds every one it
  ## needs. A find within it keeps its own holes, asks of `subjects` when it
  ## says nothing to ask of, and goes by each of its names, filled, with every
  ## binding it was filled from, so each filling is a thing of its own
  if w in holes: return b.dict[w]
  if w in kept: return w
  if w.isKind(bSet) and isFind(w):
    let own = toBSet(w.answers(hole))
    let outer = toBSet(holes.between(always, always).filters(it notin own))
    let keep = kept + own
    var used = initSet()
    needs(w, holes, used, kept)
    let by = used.members.maps((it, b.dict[it])).toSeq
    var members: seq[Value]
    for m in w.members:
      matchValue m:
      of "(identity $name)":
        if used.len > 0:
          # a name goes with every binding the filling used
          let filled = fill(name, b, outer, subjects, keep)
          let bindings = initDict(by)
          members.add bl"(identity [$filled $bindings])"
          continue
      else: discard
      members.add fill(m, b, outer, subjects, keep)
    if w.answers(ofQ).next.isNone:
      for s in subjects: members.add initRec(@[ofQ, s])
    return initSet(members, true)
  if w.isFrame: return w.map(x => fill(x, b, holes, subjects, kept))
  w

proc rows*(fd: Find, asked: Option[Value], subjects: seq[Subject]): Stream[Row] =
  ## every answer of the find `fd`, asked `asked` (none for nothing asked),
  ## of `subjects`, with the bindings it was written from and which part
  ## answered each clause: one per pull, nothing worked out ahead
  var start = initDict()
  if asked.isSome:
    for h in fd.asked: start[h] = asked.get
  let wild = randomId()
  let x = Fitting(holes: fd.holes, wild: wild, fit: fitsFor(fd.holes, wild),
                  subjects: subjects, why: fd.sayingWhy)
  var bound = initSet()
  var answered = initSet()
  var count = 0
  proc rowOf(p: Pending, parts, a: Value): Option[Row] =
    ## the row an answer written from `p` makes, once each under distinct
    if fd.once:
      if a in answered.els: return none(Row)
      answered.incl a
    var answer = a
    if fd.counting:
      inc count
      answer = num count
    elif fd.sayingWhy:
      answer = initRec(@[why, a, parts])
    some Row(answer: answer, bindings: p.b, why: p.why)
  proc rowsOf(p: Pending): Stream[Row] =
    ## the rows a binding found makes: each gives it binds wholly, written
    let parts = initSet(initStream(p.why).maps(it.part).toSeq)
    let key = if fd.sayingWhy: initList(@[p.b, parts]) else: p.b
    if key in bound.els: return empty(Row)
    bound.incl key
    var written: seq[Value]
    if fd.gives.len == 0: written.add p.b
    for g in fd.gives:
      var want = initSet()
      needs(g, fd.holes, want)
      if want.members.every(h => h in p.b.dict):
        written.add fill(g, p.b, fd.holes, fd.subjects)
    initStream(written).filterMaps(rowOf(p, parts, it))
  through(fd.wheres, Pending(b: start), x).flatMap(rowsOf)
