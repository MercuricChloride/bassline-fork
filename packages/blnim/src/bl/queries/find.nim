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

import std/[algorithm, options, sequtils, strutils]
import ../core
import ./[queries, stream, rewrite]
export rewrite

refuseWith ValueError

let
  FindKind* = sym"find"
  DistinctKind* = sym"distinct"
  CountKind* = sym"count"
  WhyKind* = sym"why"
  OfQ* = sym"of"          ## what a find asks of
  HoleQ* = sym"hole"
  AskedQ* = sym"asked"
  WhereQ* = sym"where"
  GivesQ* = sym"gives"
  WhyQ* = sym"why"
  WithinForm* = sym"within"
  AnyForm* = sym"any"
  AllForm* = sym"all"
  AsForm* = sym"as"
  QuoteForm* = sym"quote"

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
    ## which part answered a clause
    clause*, part*: Value

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
    headed*: proc(qs: seq[Question]): Stream[Hit]
    all*: proc(): Stream[Hit]

proc isFind*(v: Value): bool =
  v.hasKind(SearchSpaceKind) and v.hasKind(FindKind)

proc isForm*(p: Value): bool =
  ## whether `p` is read as a form in a clause
  p.kind == bRec and p.mark and
    (p.head == WithinForm or p.head == AnyForm or p.head == AllForm or
     p.head == AsForm or p.head == QuoteForm)

# ================ reading ================

proc checkForms(c: Value, holes: BSet) =
  ## the forms in a clause, checked: each says what it needs. Nothing under a
  ## quote is a form, nor anything in a hole
  if c in holes: return
  if isForm(c):
    let n = c.items.len - 1
    if c.head == QuoteForm:
      guard n == 1, "!(quote V) quotes one value: " & $c
      return
    guard c.head != WithinForm or n == 1,
      "!(within P) has one part to look for: " & $c
    guard c.head != AsForm or (n in 1..2 and c.items[1] in holes),
      "!(as H P) binds a hole H, to what fits P if it says one: " & $c
    guard n > 0, "!(any …) and !(all …) need a part: " & $c
  if c.kind in {bList, bRec, bDict, bSet}:
    for p in c.parts: checkForms(p, holes)

proc fromValue*(T: typedesc[Find], v: Value): Find =
  ## a find, read. Refuses a value that isn't one, a kind it doesn't read,
  ## counting together with saying why, an asked hole that isn't a hole, and
  ## a form without what it needs
  guard isFind(v), "not a find: " & $v
  let readable = [SearchSpaceKind, FindKind, DistinctKind, CountKind, WhyKind]
  let unread = v.kinds.filters(it notin readable).next
  guard unread.isNone, "a kind a find doesn't read, " & $unread.get & ", in " & $v
  result = Find(
    subjects: collect(v.answers(OfQ)),
    holes: toBTreeSet(collect(v.answers(HoleQ))),
    asked: collect(v.answers(AskedQ)),
    wheres: collect(v.answers(WhereQ)),
    gives: collect(v.answers(GivesQ)),
    once: v.hasKind(DistinctKind),
    counting: v.hasKind(CountKind),
    sayingWhy: v.hasKind(WhyKind))
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
  for (q, xs) in [(OfQ, @subjects), (HoleQ, @holes), (AskedQ, @asked),
                  (WhereQ, @wheres), (GivesQ, @gives)]:
    for x in xs: more.add initRec(@[q, x])
  describe(@[SearchSpaceKind, FindKind] & @kinds, id, more)

# ================ subjects ================

proc rankOrder(a, b: Hit): int = cmp(a.record.items[1], b.record.items[1])

proc natural(v: Value): bool =
  ## a natural, of any size
  v.kind == bNum and not v.mark and
    (if v.num.isInt: v.num.toInt >= 0 else: not v.num.wide.startsWith("-"))

proc ledHeads(space: BSet, marked: bool, led: Led): Stream[Value] =
  ## a set's records, marked or not, whose head is led as `led` says, found
  ## by bisecting
  proc pos(m: Value): int =
    if m.kind != bRec: return cmp(m.kind, bRec)
    if m.mark != marked: return cmp(m.mark, marked)
    against(m.items[0], led.kind, led.lead, led.mark)
  space.between(
    proc(it: Value): bool = pos(it) >= 0, 
    proc(it: Value): bool = pos(it) <= 0)

proc recordsFor(space: BSet, q: Question): Stream[Value] =
  ## a set's records answering `q`: headed exactly, or led
  if q.exact.isSome: space.ledBy(bRec, @[q.exact.get], q.marked)
  else: ledHeads(space, q.marked, q.led.get)

proc held*(d: Value, bodies: seq[Value], ranked, skipRefused: bool): Subject =
  ## a space holding its answers itself in `bodies`, each a set of records
  ## or, unranked, a dict. A question, (Q) alone, is passed over; any other
  ## record that isn't (Q A), or (Q R A) with R a natural when ranked, is
  ## refused unless refusals are passed over
  let part = identityOf(d)
  proc holds(r: Value): bool =
    if r.kind == bRec and r.items.len == 1: return false
    result = r.kind == bRec and not r.mark and
      (if ranked: r.items.len == 3 and natural(r.items[1]) else: r.items.len == 2)
    if not result and not skipRefused:
      refuse "not a (query " & (if ranked: "rank " else: "") &
             "answer) record: " & $r
  let hit = proc(r: Value): Hit = Hit(record: r, part: part, ranked: ranked)
  proc bodyHits(b: Value, q: Option[Question]): Stream[Hit] =
    if b.kind == bDict:
      if q.isSome and q.get.exact.isSome:
        let head = q.get.exact.get
        if head notin b.dict: return empty Hit
        return just(hit(initRec(@[head, b.dict[head]])))
      return b.entries
        .filters(
          q.isNone or against(it[0], q.get.led.get.kind, q.get.led.get.lead,
                              q.get.led.get.mark) == 0)
        .maps(hit(initRec(@[it[0], it[1]])))
    if q.isSome: return recordsFor(b.els, q.get).filters(holds(it)).maps(hit(it))
    if not ranked: return b.members.filters(holds(it)).maps(hit(it))
    # all of a ranked body, in rank order
    lazy(proc(): Stream[Hit] =
      initStream(collect(b.members.filters(holds(it)).maps(hit(it))).sorted(rankOrder)))
  proc bodiesFor(q: Option[Question]): seq[Stream[Hit]] =
    collect(initStream(bodies).maps(bodyHits(it, q)))
  proc join(qs: seq[Option[Question]]): Stream[Hit] =
    var each: seq[Stream[Hit]]
    for q in qs:
      let streams = bodiesFor(q)
      if ranked: each.add streams else: each.add cat(streams)
    if ranked: merge(rankOrder, each) else: alt(each)
  Subject(headed: proc(qs: seq[Question]): Stream[Hit] =
            join(collect(initStream(qs).filters(not it.marked).maps(some it))),
          all: proc(): Stream[Hit] = join(@[none Question]))

proc thing*(d: Value): Subject =
  ## an object that isn't a search space: what it answers, (Q A), and its
  ## orders, !(Q A)
  let part = identityOf(d)
  let hit = proc(r: Value): Hit = Hit(record: r, part: part)
  Subject(headed: proc(qs: seq[Question]): Stream[Hit] =
            alt(collect(initStream(qs).maps(
              recordsFor(d.els, it).filters(it.items.len == 2).maps(hit it)))),
          all: proc(): Stream[Hit] =
            d.members.filters(it.kind == bRec and it.items.len == 2).maps(hit it))

proc answering*(ask: proc(q: Value): Stream[Value], part: Value): Subject =
  ## a search, going by `part`, which answers what it is asked and can't say
  ## what it holds
  Subject(
    headed: proc(qs: seq[Question]): Stream[Hit] =
      alt(collect(
        initStream(qs).maps(
          block:
            let head = if it.exact.isSome: it.exact else: it.value
            if it.marked or head.isNone: 
              empty Hit
            else: 
              ask(head.get).maps(Hit(record: initRec(@[head.get, it]), part: part))
        ))),
    all: proc(): Stream[Hit] = empty Hit)

proc joined*(kind: Value, parts: seq[Subject]): Subject =
  ## parts joined as a composite of `kind` joins them: one after another for
  ## a cat, merged by rank for a merge, and otherwise taking turns
  proc join(each: proc(p: Subject): Stream[Hit]): Stream[Hit] =
    if kind == CatKind: 
      return catFrom(initStream(parts).maps(each(it)))
    let streams = collect(initStream(parts).maps(each(it)))
    if kind == MergeKind: 
      merge(rankOrder, streams)
    else: 
      alt(streams)
  Subject(headed: proc(qs: seq[Question]): Stream[Hit] =
            join(proc(p: Subject): Stream[Hit] = p.headed(qs)),
          all: proc(): Stream[Hit] =
            join(proc(p: Subject): Stream[Hit] = p.all()))

proc fed*(first, then: Subject): Subject =
  ## each answer of `first` asked of `then`, their records taking turns as
  ## they arrive: (Q A) or (Q R A), as `then` answers A to `first`'s
  ## answer. It can say all it holds when `first` can
  proc through(hits: Stream[Hit]): Stream[Hit] =
    altFrom(hits.map(
      proc(h: Hit): auto =
        then
          .headed(@[Question(exact: some h.record.items[^1])])
          .map(
            proc(t: Hit): Hit =
              let r = if t.ranked:
                  @[h.record.items[0], t.record.items[1], t.record.items[2]]
                else:
                  @[h.record.items[0], t.record.items[1]]
              Hit(record: initRec(r), part: t.part, ranked: t.ranked))))
  Subject(headed: proc(qs: seq[Question]): Stream[Hit] =
            through(first.headed(collect(initStream(qs).filters(not it.marked)))),
          all: proc(): Stream[Hit] = through(first.all()))

# ================ fitting ================

proc andThen(a, b: Fit): Fit =
  proc(x: Value): Stream[Value] = a(x).flatMap(b)

proc fitForm(part, v: Value, fit: proc(part, v: Value): Fit): Fit =
  ## every extension of bindings under which `v` fits the form `part`
  let args = part.items.data[1 .. ^1]
  if part.head == QuoteForm:
    let quoted = args[0]
    return proc(b: Value): Stream[Value] =
      if quoted == v: just(b) else: empty Value
  if part.head == AnyForm:
    let fits = collect(initStream(args).maps(fit(it, v)))
    return proc(b: Value): Stream[Value] =
      alt(collect(initStream(fits).maps(it(b))))
  if part.head == AsForm:
    let hole = args[0]
    let inner = if args.len == 2: some args[1] else: none(Value)
    return proc(b: Value): Stream[Value] =
      if hole in b.dict and b.dict[hole] != v: return empty Value
      var bound = b
      if hole notin b.dict:
        let more = b.dict + newBDict()
        more[hole] = v
        bound = initDict(more)
      if inner.isNone: just(bound) else: fit(inner.get, v)(bound)
  if part.head == AllForm:
    result = fit(args[0], v)
    for p in args[1 .. ^1]: result = andThen(result, fit(p, v))
    return
  let inner = args[0]  # within: v or anything in it
  proc(b: Value): Stream[Value] =
    walk(v).flatMap(proc(x: Value): Stream[Value] = fit(inner, x)(b)).unique

proc fitsFor(holes: BSet, wild: Value): proc(part, v: Value): Fit =
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
    fit: proc(part, v: Value): Fit
    subjects: seq[Subject]
    why: bool  ## whether the parts that answered are said, so a binding
               ## counts once per part

proc unboundIn(c: Value, holes: BSet, b: Value): int =
  ## how many holes in `c` the bindings leave unbound, each once; none under
  ## a quote
  let open = newBSet()
  proc look(p: Value) =
    if p in holes:
      if p notin b.dict: open.incl p
      return
    if isForm(p) and p.head == QuoteForm: return
    if p.kind in {bList, bRec, bDict, bSet}:
      for x in p.parts: look(x)
  look(c)
  open.len

proc exact(v: Value, holes: BSet, b: Value): bool =
  ## whether `v` fits exactly one value, once filled from `b`: an atom, a
  ## hole bound, a quote, an `as` whose hole is bound or whose part is
  ## exact, an `all` with an exact part. A list, record, dict or set fits
  ## more than itself, and is never exact
  if v in holes: return v in b.dict
  if isForm(v):
    let args = v.items.data[1 .. ^1]
    if v.head == QuoteForm: return true
    if v.head == AsForm:
      return args[0] in b.dict or (args.len == 2 and exact(args[1], holes, b))
    if v.head == AllForm:
      return initStream(args).exists(proc(p: Value): bool = exact(p, holes, b))
    return false
  v.kind notin {bList, bRec, bDict, bSet}

proc settled(v: Value, holes: BSet, b: Value): bool =
  ## whether `v` holds no unbound hole and no form but an exact one: so
  ## filled, it is one value
  if v in holes or isForm(v): return exact(v, holes, b)
  if v.kind in {bList, bRec, bDict, bSet}:
    return v.parts.every(proc(p: Value): bool = settled(p, holes, b))
  true

proc valueOf(v: Value, holes: BSet, b: Value): Value =
  ## the settled `v` as one value: its holes filled from `b`, its exact
  ## forms what they fit
  if v in holes: return b.dict[v]
  if isForm(v):
    let args = v.items.data[1 .. ^1]
    if v.head == QuoteForm: return args[0]
    if v.head == AsForm:
      return (if args[0] in b.dict: b.dict[args[0]] else: valueOf(args[1], holes, b))
    for p in args:
      if exact(p, holes, b): return valueOf(p, holes, b)
  if v.kind in {bList, bRec, bDict, bSet}:
    return v.map(proc(p: Value): Value = valueOf(p, holes, b))
  v

proc questionIn(w: Value): Option[seq[Question]] =
  ## the questions of the one value `w`: its head exactly if it is a record,
  ## and none if it isn't, since then no record fits
  if w.kind == bRec: some @[Question(marked: w.mark, exact: some w.head)]
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
    let args = p.items.data[1 .. ^1]
    if p.head == AsForm and args.len == 2: return headsOf(args[1], holes, b)
    if p.head == AllForm:
      return firstOf(collect(initStream(args).maps(headsOf(it, holes, b))))
    if p.head == AnyForm:
      return unionOf(collect(initStream(args).maps(
        headsOf(it, holes, b))))
    return
  if p.kind notin {bList, bRec}: return
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
  if exact(c, holes, b): return questionIn(valueOf(c, holes, b))
  if c in holes: return
  if isForm(c):
    let args = c.items.data[1 .. ^1]
    if c.head == AsForm and args.len == 2: return questionsOf(args[1], holes, b)
    if c.head == AllForm:
      return firstOf(collect(initStream(args).maps(
        questionsOf(it, holes, b))))
    if c.head == AnyForm:
      return unionOf(collect(initStream(args).maps(
        questionsOf(it, holes, b))))
    return
  # an atom, list, dict or set fits no record
  if c.kind != bRec: return some newSeq[Question]()
  let heads = headsOf(c.head, holes, b)
  if heads.isNone: return
  some collect(initStream(heads.get).maps(
    block:
      var q = it
      q.marked = c.mark
      q))

proc rankless(c, wild: Value, holes: BSet): Value =
  ## the clause `c` as it meets a ranked record (Q R A): a record of two
  ## fields with `wild` in the rank's place, and so the record parts of the
  ## forms that meet the record itself. Holes and forms still meet the
  ## record as held, its rank and all
  if c.kind != bRec or c in holes: return c
  if not isForm(c):
    return (if c.items.len == 2: initRec(@[c.items[0], wild, c.items[1]], c.mark) else: c)
  if c.head == AnyForm or c.head == AllForm:
    var items = @[c.head]
    for x in c.items.data[1 .. ^1]: items.add rankless(x, wild, holes)
    return initRec(items, true)
  if c.head == AsForm and c.items.len == 3:
    return initRec(@[c.head, c.items[1], rankless(c.items[2], wild, holes)], true)
  c

proc step(c: Value, p: Pending, x: Fitting): Stream[Pending] =
  ## every extension of `p` under which one of the subjects' records fits the
  ## clause `c`: each once, or once for each part that answers it when the
  ## find says why
  let questions = questionsOf(c, x.holes, p.b)
  let hits = alt(collect(initStream(x.subjects).maps(
    if questions.isNone: it.all()
    else: it.headed(questions.get))))
  let ranklessly = rankless(c, x.wild, x.holes)
  let given = newBSet()
  hits.flatMap(proc(hit: Hit): Stream[Pending] =
    x.fit(if hit.ranked: ranklessly else: c, hit.record)(p.b)
      .filter(proc(b: Value): bool =
        let key = if x.why: initList(@[b, hit.part]) else: b
        result = key notin given
        if result: given.incl key)
      .map(proc(b: Value): Pending =
        Pending(b: b, why: p.why & Because(clause: c, part: hit.part))))

proc through(clauses: seq[Value], p: Pending, x: Fitting): Stream[Pending] =
  ## the clauses fed one into the next, the next chosen each time: one that
  ## only checks, then one whose question is settled, then any other, fewest
  ## holes unbound first. A clause that only checks is asked for one answer,
  ## or one for each part that answers it when the find says why. What each
  ## binding leads to takes turns, so none starves the others
  if clauses.len == 0: return just(p)
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
    return lazy(proc(): Stream[Pending] =
      let one = step(c, p, x)()
      if one.isSome: through(rest, one.get, x) else: empty Pending)
  altFrom(step(c, p, x).map(proc(next: Pending): Stream[Pending] =
    through(rest, next, x)))

proc needs(w: Value, holes: BSet, into: BSet, kept = newBSet()) =
  ## the holes of `holes` that `w` needs bound to be written: those in it, a
  ## find within it keeping its own, whole, and so `kept`, the holes of finds
  ## it is within
  if w in holes:
    into.incl w
    return
  if w in kept: return
  if w.kind == bSet and isFind(w):
    let own = toBTreeSet(collect(w.answers(HoleQ)))
    let outer = toBTreeSet(collect(holes.between(always, always)
      .filter(Value -> it notin own)))
    let keep = kept + own
    for m in w.els.between(always, always): needs(m, outer, into, keep)
    return
  if w.kind in {bList, bRec, bDict, bSet}:
    for p in w.parts: needs(p, holes, into, kept)

proc fill(w, b: Value, holes: BSet, subjects: seq[Value], kept = newBSet()): Value =
  ## `w` with each hole of `holes` filled from `b`, which binds every one it
  ## needs. A find within it keeps its own holes, asks of `subjects` when it
  ## says nothing to ask of, and goes by each of its names, filled, with every
  ## binding it was filled from, so each filling is a thing of its own
  if w in holes: return b.dict[w]
  if w in kept: return w
  if w.kind == bSet and isFind(w):
    let own = toBTreeSet(collect(w.answers(HoleQ)))
    let outer = toBTreeSet(collect(holes.between(always, always)
      .filter(Value -> it notin own)))
    let keep = kept + own
    let used = newBSet()
    needs(w, holes, used, kept)
    var by: seq[(Value, Value)]
    for h in used.between(always, always): by.add (h, b.dict[h])
    var members: seq[Value]
    for m in w.els.between(always, always):
      let name = m.kind == bRec and not m.mark and m.items.len == 2 and
                 m.head == IdentityQ
      if name and used.len > 0:
        # a name goes with every binding the filling used
        members.add initRec(@[IdentityQ, initList(@[fill(m.items[1], b, outer, subjects, keep),
                                                    initDict(by)])])
        continue
      members.add fill(m, b, outer, subjects, keep)
    if w.answers(OfQ).next.isNone:
      for s in subjects: members.add initRec(@[OfQ, s])
    return initSet(members, true)
  if w.kind in {bList, bRec, bDict, bSet}:
    return w.map(proc(x: Value): Value = fill(x, b, holes, subjects, kept))
  w

proc rows*(fd: Find, asked: Option[Value], subjects: seq[Subject]):
    Stream[Row] =
  ## every answer of the find `fd`, asked `asked` (none for nothing asked),
  ## of `subjects`, with the bindings it was written from and which part
  ## answered each clause: one per pull, nothing worked out ahead
  let start = newBDict()
  if asked.isSome:
    for h in fd.asked: start[h] = asked.get
  let wild = randomId()
  let x = Fitting(holes: fd.holes, wild: wild, fit: fitsFor(fd.holes, wild),
                  subjects: subjects, why: fd.sayingWhy)
  let bound = newBSet()
  let answered = newBSet()
  var count = 0
  through(fd.wheres, Pending(b: initDict(start)), x)
    .flatMap(proc(p: Pending): Stream[Row] =
      let parts = initSet(collect(initStream(p.why).map(proc(w: Because): Value = w.part)))
      let key = if fd.sayingWhy: initList(@[p.b, parts]) else: p.b
      if key in bound: return empty Row
      bound.incl key
      var written: seq[Value]
      if fd.gives.len == 0: written.add p.b
      for g in fd.gives:
        let want = newBSet()
        needs(g, fd.holes, want)
        if want.between(always, always).every(Value -> it in p.b.dict):
          written.add fill(g, p.b, fd.holes, fd.subjects)
      initStream(written).filterMap(proc(a: Value): Option[Row] =
        if fd.once:
          if a in answered: return none(Row)
          answered.incl a
        var answer = a
        if fd.counting:
          inc count
          answer = num(count)
        elif fd.sayingWhy:
          answer = initRec(@[WhyQ, a, parts])
        some Row(answer: answer, bindings: p.b, why: p.why)))
