## Searches: what you ask, handing back a stream you pull.
##
## A search closes over whatever it answers from; how it got there is
## its own construction. Searches compose into new searches: one after
## another (`cat`, as a scope falls back to the scope around it), taking
## turns (`alt`), answers fed on as questions (`feed`), ranked answers
## merged by rank (`merge`), and one search's answers asked of it again,
## nearest first (`more`).
##
## Some searches can also be written down: their space denoted as an
## object, which interpreting turns back into a search, answers rebuilt
## from their values by the answer type's reading. Most searches never
## are, since most spaces aren't worth the bytes, but one that is can be
## memoised (`bl/queries/bvar`) and talked about like any value: test cases,
## what an evaluator found, what a program was connected to. Its kinds,
## together, say how to bring it about (`bl/queries/queries`):
##
##   !{!(kind search-space) (identity ID) (holds {(Q A) …})}
##   !{!(kind search-space) (identity ID) (holds {Q: A …})}     ; one answer a query
##   !{!(kind search-space) !(kind ranked) (identity ID) (holds {(Q R A) …})}
##   !{!(kind search-space) !(kind cat) (identity ID) (parts [PART …])}
##
## and `alt`, `feed` and `merge` like `cat`, and `more` with one part,
## `!(kind via)` with it answering the way each answer was reached; R is a
## natural, and a part is an object, or names of a thing written down
## elsewhere.
##
## A one-field record (Q) in a space is a question, Q being asked, not
## an answer; it sorts after Q's answers, so a query's run holds both,
## and answering passes over it. A record's head is the query, so CE
## order keeps one query's records together, and in a ranked space puts
## them in rank order. Several `holds` answers are all read, and joined
## as the kind joins its parts: one after another, or merged by rank when
## ranked. A denoted space may name a part rather than carry it; the
## name is resolved, when the search is asked, through a search of known
## spaces, and a name met again on its own way round is passed over.
##
## A find (`bl/queries/find`) is one more kind of search space, read here
## like any other and asked with its asked holes bound to the query.

import std/sequtils
import ../core
import ./[queries, stream, find]
export queries, stream, find

refuseWith BasslineError

type
  Fanout* = enum
    ## how many answers a query may have: any number, as a set of records
    ## holds them, or at most one, as a dict does
    many, one

  Search*[Q, A] = ref object
    fanning: Fanout
    asking: (Q) -> Stream[A]
    denoting: () -> Value     ## nil for a search with no denotation
    identifying: () -> Value  ## the ID it goes by, without writing it down

  Ranked*[A] = object
    ## an answer from a ranked search, and where it ranks: lowest first
    rank*: Natural
    answer*: A

proc atMostOne[Q, A](ask: (Q) -> Stream[A]): (Q) -> Stream[A] =
  ## `ask`, its streams stopping after their first answer
  (q: Q) => (block:
    let s = ask(q)
    var given = false
    () => (block:
      if given: return none(A)
      given = true
      s()))

proc newSearch*[Q, A](ask: (Q) -> Stream[A], denote: () -> Value = nil,
                      id: () -> Value = nil, fanout = many): Search[Q, A] =
  ## a search that answers with `ask`, that writes its space down with
  ## `denote` if it can, and says what ID it goes by with `id`. With
  ## `fanout = one` a query has at most one answer, as from a dict
  Search[Q, A](fanning: fanout, denoting: denote, identifying: id,
               asking: if fanout == one: atMostOne(ask) else: ask)

proc newSearch*[Q, A](ask: (Q) -> Stream[A], denote: () -> Value = nil,
                      id: Value, fanout = many): Search[Q, A] =
  ## the same, going by the ID `id`
  newSearch(ask, denote, k(id), fanout)

proc writtenAs[Q, A](s: Search[Q, A], denote, id: () -> Value): Search[Q, A] =
  ## `s` as it answers, written down with `denote` and going by `id`
  Search[Q, A](fanning: s.fanning, asking: s.asking, denoting: denote,
               identifying: id)

proc fanout*(s: Search): Fanout =
  ## how many answers a query of `s` may have
  s.fanning

proc ask*[Q, A](s: Search[Q, A], q: Q): Stream[A] =
  s.asking(q)

proc `[]`*[Q, A](s: Search[Q, A], q: Q): Stream[A] =
  ## alias for `ask`
  s.asking(q)

proc `?`*[Q, A](s: Search[Q, A], q: Q): Option[A] =
  ## returns the first answer to `q`
  s.asking(q)()

proc denotable*(s: Search): bool =
  s.denoting != nil

proc toValue*(s: Search): Value =
  ## the search written down: its denotation. Refuses a search that has
  ## none (`byId` gives one written down by its ID)
  guard s.denotable, "this search has no denotation"
  s.denoting()

proc id*(s: Search): Value =
  ## the ID the search goes by. One built without an id proc is asked
  ## for its denotation instead, which may cost writing it all down.
  ## Refuses a search with neither
  if s.identifying != nil: return s.identifying()
  identityOf s.toValue

proc byId*[Q, A](s: Search[Q, A]): Search[Q, A] =
  ## `s`, written down by its ID alone: a composite that holds it names
  ## it rather than carrying it whole
  let name = () => s.id
  s.writtenAs(name, name)

type Walked = object
  ## a value reached, and the values walked through on the way to it
  value: Value
  path: seq[Value]

proc more*(step: Search[Value, Value], id = randomId(), via = false):
    Search[Value, Value] =
  ## `step` asked again of each answer it gives, nearest first: asked q, it
  ## answers what `step` answers to q, then what it answers to each of
  ## those, and so on, each value once, so a walk that comes round again
  ## ends. Answers the same distance away take turns. With `via` each answer
  ## is (via [Q … PREVIOUS] A), the values walked through to reach it
  proc ask(q: Value): Stream[Value] =
    var answered = initSet()
    var expanded = initSet(@[q])
    var level = @[Walked(value: q)]
    var next: seq[Walked]
    var current: Stream[Walked] = nil
    () => (block:
      while true:
        if current == nil:
          if level.len == 0: return none(Value)
          current = alt initStream(level).maps(block:
            let w = it
            step.ask(w.value).maps(Walked(value: it, path: w.path & w.value))).toSeq
        let got = current()
        if got.isNone:
          level = next
          next = @[]
          current = nil
          continue
        let w = got.get
        if w.value in answered.els: continue
        answered.incl w.value
        if w.value notin expanded.els:
          expanded.incl w.value
          next.add w
        return some(if via: initRec(@[ViaKind, initList(w.path), w.value])
                    else: w.value))
  let denote =
    if step.denotable:
      () => describe(if via: @[SearchSpaceKind, MoreKind, ViaKind]
                     else: @[SearchSpaceKind, MoreKind],
                     id, initRec(@[PartsQ, initList(@[step.toValue])]))
    else: nil
  newSearch[Value, Value](ask, denote, k(id))

proc byRank*[R: Ranked](streams: varargs[Stream[R]]): Stream[R] =
  ## ranked streams, each in rank order, merged by rank, lowest first; on
  ## a tie the earlier stream goes first
  merge((a, b: R) => cmp(a.rank, b.rank), streams)

# ================ composing ================

proc denoteParts[A](kind, id: Value, parts: seq[Value]): Value =
  ## a composite written down: a search space of its kind, ranked when its
  ## answers are
  let ks = when A is Ranked: @[SearchSpaceKind, kind, RankedKind]
           else: @[SearchSpaceKind, kind]
  describe(ks, id, initRec(@[PartsQ, initList(parts)]))

proc partsDenoter[Q, A](kind, id: Value, parts: seq[Search[Q, A]]): () -> Value =
  ## a composite's denotation, if every part has one
  if not initStream(parts).every(p => p.denotable): return nil
  () => denoteParts[A](kind, id, initStream(parts).maps(it.toValue).toSeq)

proc cat*[Q, A](parts: openArray[Search[Q, A]], id = randomId()): Search[Q, A] =
  ## each part's answers in turn, a part asked only once the one before
  ## it has nothing more: a scope, then the scope around it
  let ps = @parts
  newSearch[Q, A]((q: Q) => initStream(ps).flatMaps(it.ask(q)),
                  partsDenoter(CatKind, id, ps), k(id))

proc asked[Q, A](ps: seq[Search[Q, A]], q: Q): seq[Stream[A]] =
  ## each part's stream for `q`
  initStream(ps).maps(it.ask(q)).toSeq

proc alt*[Q, A](parts: openArray[Search[Q, A]], id = randomId()): Search[Q, A] =
  ## the parts' answers taking turns, so no part starves the others
  let ps = @parts
  newSearch[Q, A]((q: Q) => alt(ps.asked(q)), partsDenoter(AltKind, id, ps), k(id))

proc feed*[Q, M, A](first: Search[Q, M], then: Search[M, A],
                    id = randomId()): Search[Q, A] =
  ## each answer of `first` asked of `then`, their streams taking turns
  ## as they arrive
  let denote =
    if first.denotable and then.denotable:
      () => denoteParts[A](FeedKind, id, @[first.toValue, then.toValue])
    else: nil
  newSearch[Q, A]((q: Q) => altFrom(first.ask(q).maps(then.ask(it))), denote, k(id),
                  if first.fanout == one and then.fanout == one: one else: many)

proc merge*[Q; R: Ranked](parts: openArray[Search[Q, R]], id = randomId()):
    Search[Q, R] =
  ## ranked parts' answers merged by rank, lowest first; on a tie the
  ## earlier part goes first
  let ps = @parts
  newSearch[Q, R]((q: Q) => byRank(ps.asked(q)), partsDenoter(MergeKind, id, ps), k(id))

# ================ interpreting a denotation ================

proc reading[A](v: Value, skipRefused: bool): Option[A] =
  ## A's reading of v, none if it refuses and refusals are skipped
  mixin fromValue
  try:
    some A.fromValue(v)
  except ValueError:
    if not skipRefused: raise
    none(A)

proc natural(v: Value): bool =
  v.isKind(bNum, unmarked) and v.num.isInt and v.num.toInt >= 0

proc readBack[A](records: Stream[Value], ranked, skipRefused: bool): Stream[A] =
  ## each record's answer, read back. A question, (Q) alone, is passed
  ## over. A record the space can't hold as an answer (a field too many,
  ## a rank that isn't a natural) is refused like one whose answer A's
  ## reading refuses
  mixin fromValue
  let width = if ranked: 3 else: 2
  proc held(r: Value): bool =
    if r.items.len == 1: return false  # a question, not an answer
    result = r.items.len == width and (not ranked or natural(r.items[1]))
    if not result and not skipRefused:
      refuse "not a (query " & (if ranked: "rank " else: "") & "answer) record: " & $r
  proc read(r: Value): Option[A] =
    when A is Ranked:
      let a = reading[typeof(default(A).answer)](r.items[2], skipRefused)
      if a.isSome: some A(rank: r.items[1].num.toInt, answer: a.get) else: none(A)
    else:
      reading[A](r.items[^1], skipRefused)
  records.filter(held).filterMap(read)

proc setAsk[Q, A](els: BSet, skipRefused: bool): (Q) -> Stream[A] =
  ## asking a set of records: those headed by the query, read back
  mixin toValue
  (q: Q) => readBack[A](els.headed(q.toValue), A is Ranked, skipRefused)

proc dictAsk[Q, A](d: BDict, skipRefused: bool): (Q) -> Stream[A] =
  ## asking a dict: the query's one answer, if it has one, read back
  mixin toValue
  (q: Q) => (block:
    let query = q.toValue
    if query notin d: return empty(A)
    readBack[A](just(initRec(@[query, d[query]])), false, skipRefused))

proc spaceKinds[A](): seq[Value] =
  when A is Ranked: @[SearchSpaceKind, RankedKind] else: @[SearchSpaceKind]

proc searchOver*[Q, A](space: BSet, id: Value, skipRefused = false): Search[Q, A] =
  ## a search over a set of records held now, which may still grow: each
  ## ask sees it as it stands, and a stream keeps seeing what is added
  ## past where it has got to. Written down, it is a copy of the set as
  ## it stands then, so the value never changes after
  let copied = () => describe(spaceKinds[A](), id, initRec(@[HoldsQ, initSet(space.copy)]))
  newSearch[Q, A](setAsk[Q, A](space, skipRefused), copied, k(id), many)

proc searchOver*[Q, A](space: BDict, id: Value, skipRefused = false): Search[Q, A] =
  ## a search over a dict held now: one answer a query, and the same
  ## copy taken to write it down
  when A is Ranked:
    {.error: "a ranked search has any number of answers, so no dict".}
  let copied = () => describe([SearchSpaceKind], id, initRec(@[HoldsQ, initDict(space.copy)]))
  newSearch[Q, A](dictAsk[Q, A](space, skipRefused), copied, k(id), one)

proc compositeOf*(d: Value, ranked: bool): Value =
  ## how a search space's parts are read, nil for a space that holds its
  ## answers itself. Each kind says its own part: `search-space` that it
  ## is a search, `ranked` that its answers are ranked, and a composite
  ## kind how its parts are read. Refuses a kind it can't carry out, two
  ## ways of reading the parts at once, and a space ranked otherwise than
  ## `ranked`, and `via` but on a `more`
  let composites = [CatKind, AltKind, FeedKind, MergeKind, MoreKind]
  let unread = d.kinds.filters(
    it notin composites and it notin [SearchSpaceKind, RankedKind, ViaKind]).next
  guard unread.isNone, "a kind this doesn't read, " & $unread.get & ", in " & $d
  guard not d.hasKind(ViaKind) or d.hasKind(MoreKind),
    "via is the way a more reached its answers: " & $d
  guard d.hasKind(RankedKind) == ranked,
    (if ranked: "an unranked space, read as ranked: "
     else: "a ranked space, read as unranked: ") & $d
  let found = d.kinds.filters(it in composites).take(2)
  guard found.len < 2, "a search space read as two composites: " & $d
  if found.len == 1: found[0] else: null()

proc spaceBodies*(d: Value, ranked: bool): seq[Value] =
  ## everything a denoted space holds: every `holds` answer, each a set of
  ## records or, unranked, a dict. Refuses a space holding nothing, and a
  ## body it can't hold
  result = d.answers(HoldsQ).taps(guard(
    it.isKind(bSet, unmarked) or (not ranked and it.isKind(bDict, unmarked)),
    "a space holds sets of records" & (if ranked: "" else: " or dicts") & ": " & $d)).toSeq
  guard result.len > 0, "a space that holds nothing said: " & $d

proc bodyAsk[Q, A](b: Value, skipRefused: bool): (Q) -> Stream[A] =
  ## asking one body a denoted space holds
  when A is Ranked: setAsk[Q, A](b.els, skipRefused)
  else:
    if b.isKind(bDict): dictAsk[Q, A](b.dict, skipRefused)
    else: setAsk[Q, A](b.els, skipRefused)

proc space[Q, A](d: Value, skipRefused: bool): Search[Q, A] =
  ## the search a denoted space stands for, answering from every body it
  ## holds: in turn, or merged by rank when its answers are ranked. One
  ## answer a query only when it holds one dict
  let bodies = spaceBodies(d, A is Ranked)
  proc ask(q: Q): Stream[A] =
    let streams = initStream(bodies).maps(bodyAsk[Q, A](it, skipRefused)(q)).toSeq
    when A is Ranked: byRank(streams) else: cat(streams)
  newSearch[Q, A](ask, k(d), k(identityOf d),
                  if bodies.len == 1 and bodies[0].isKind(bDict): one else: many)

proc interpret[Q, A](d: Value, skipRefused: bool,
                     resolve: Search[Value, Value], followed: BSet): Search[Q, A]

type Asking = object
  ## how a find is asked: names already followed on the way to it, and
  ## whether refusals are passed over
  followed: BSet
  skipRefused: bool

proc findAsked(d: Value, resolve: Search[Value, Value], how: Asking):
    Search[Value, Value]

proc named[Q, A](name: Value, skipRefused: bool,
                 resolve: Search[Value, Value], followed: BSet): Search[Q, A] =
  ## the search a name stands for: asked, it asks `resolve` about each
  ## name, as things stand then, and answers from each space found in
  ## turn, once however many names find it. A name already followed on
  ## the way here is passed over, so names that lead round to themselves
  ## come to an end. Written down, it is the name again
  guard resolve != nil, "names a space, with nothing to resolve it: " & $name
  proc ask(q: Q): Stream[A] =
    let fresh = identities(name).filters(it notin followed).toSeq
    let now = followed + toBTreeSet(fresh)
    initStream(fresh)
      .flatMaps(resolve.ask(it))
      .unique
      .flatMaps(interpret[Q, A](it, skipRefused, resolve, now).ask(q))
  newSearch[Q, A](ask, k(name), k(name))

proc combine[Q, A](kind: Value, ps: seq[Search[Q, A]], id: Value): Search[Q, A] =
  ## searches joined as a composite of `kind` joins its parts: one after
  ## another for a cat, merged by rank for a merge, and otherwise taking
  ## turns, as an alt's parts do and a feed's streams do
  when A is Ranked:
    if kind == MergeKind: return merge(ps, id)
  if kind == CatKind: cat(ps, id) else: alt(ps, id)

proc composite[Q, A](kind, parts, id: Value, via, skipRefused: bool,
                     resolve: Search[Value, Value], followed: BSet): Search[Q, A] =
  ## the composite one list of parts stands for
  mixin toValue
  guard parts.isKind(bList, unmarked), "a composite's parts are a list: " & $parts
  if kind == MoreKind:
    guard parts.items.len == 1, "a more has one part: " & $parts
    when A is Ranked:
      refuse "a more's answers are not ranked: " & $parts
    else:
      let walking = more(interpret[Value, Value](parts.items[0], skipRefused,
                                                 resolve, followed), id, via)
      return newSearch[Q, A](
        (q: Q) => walking.ask(q.toValue).filterMaps(reading[A](it, skipRefused)),
        nil, k(id))
  if kind == FeedKind:
    guard parts.items.len == 2, "a feed has two parts: " & $parts
    return feed(
      interpret[Q, Value](parts.items[0], skipRefused, resolve, followed),
      interpret[Value, A](parts.items[1], skipRefused, resolve, followed), id)
  combine(kind, initStream(parts.items.data).maps(interpret[Q, A](it, skipRefused, resolve, followed)).toSeq, id)

proc interpret[Q, A](d: Value, skipRefused: bool,
                     resolve: Search[Value, Value], followed: BSet): Search[Q, A] =
  ## the search `d` stands for, `followed` the names already followed on
  ## the way to it
  mixin toValue
  if not d.hasKind(SearchSpaceKind):
    guard d.kinds.next.isNone, "neither a search nor names of one: " & $d
    return named[Q, A](d, skipRefused, resolve, followed)
  if isFind(d):
    when A is Ranked:
      refuse "a find's answers are not ranked: " & $d
    else:
      let answering = findAsked(d, resolve, Asking(followed: followed, skipRefused: skipRefused))
      return newSearch[Q, A](
        (q: Q) => answering.ask(q.toValue).filterMaps(reading[A](it, skipRefused)),
        k(d), k(identityOf d))
  let kind = compositeOf(d, A is Ranked)
  if kind.isKind(bNil):
    return space[Q, A](d, skipRefused)
  guard kind != MergeKind or A is Ranked, "a merge is of ranked searches: " & $d
  let id = identityOf d
  let made = d.answers(PartsQ).maps(
    composite[Q, A](kind, it, id, d.hasKind(ViaKind), skipRefused, resolve, followed)).toSeq
  guard made.len > 0, "a composite with no parts said: " & $d
  let whole = if made.len == 1: made[0] else: combine(kind, made, id)
  whole.writtenAs(k(d), k(id))

proc fromValue*[Q, A](T: typedesc[Search[Q, A]], d: Value, skipRefused = false,
                      resolve: Search[Value, Value] = nil): Search[Q, A] =
  ## the search a denotation stands for, written down again as exactly
  ## that. A space answers asked q from the records headed by q's value,
  ## each read back as an A; a refusal raises unless `skipRefused`,
  ## which passes over it. A space is ranked exactly when its answers
  ## are. Several `holds` or `parts` answers are all read, joined as the
  ## kind joins its parts (merged by rank when ranked). A part that is
  ## only names is asked of `resolve` when the search is asked, and a
  ## name met again on its own way round is passed over. A feed's parts
  ## meet in values
  interpret[Q, A](d, skipRefused, resolve, newBSet())

# ================ finds ================

proc subjectOf(v: Value, resolve: Search[Value, Value], how: Asking,
               within = none(bool)): Subject

proc namedSubject(names: Value, resolve: Search[Value, Value],
                  how: Asking, within: Option[bool]): Subject =
  ## what names stand for: asked, each name not yet followed is asked of
  ## `resolve`, as things stand then, and each thing found answers in turn,
  ## once however many names find it. Refuses names with nothing to resolve
  ## them
  guard resolve != nil, "names a space, with nothing to resolve it: " & $names
  proc found(): Stream[Subject] =
    let fresh = identities(names).filters(it notin how.followed).toSeq
    let now = Asking(followed: how.followed + toBTreeSet(fresh),
                     skipRefused: how.skipRefused)
    initStream(fresh)
      .flatMaps(resolve.ask(it))
      .unique
      .maps(subjectOf(it, resolve, now, within))
  Subject(headed: (qs: seq[Question]) => found().flatMaps(it.headed(qs)),
          all: () => found().flatMaps(it.all()))

proc asSubject*(s: Search[Value, Value]): Subject =
  ## a search running here as something a find asks of: it answers what it
  ## is asked, and can't say what it holds
  let part = try: s.id except ValueError: null()
  answering(q => s.ask(q), part)

proc subjectOf(v: Value, resolve: Search[Value, Value], how: Asking,
               within = none(bool)): Subject =
  ## the subject `v` is, read as `fromValue` reads a space and refusing what
  ## it refuses: a search space, an object, or names of one. A part of a
  ## composite is a search ranked as the composite is (`within`); what a
  ## find asks of directly may be any object, ranked or not
  if not v.isObject or v.kinds.next.isNone:
    return namedSubject(v, resolve, how, within)
  if not v.hasKind(SearchSpaceKind):
    guard within.isNone, "neither a search nor names of one: " & $v
    return thing(v)
  if isFind(v):
    guard within != some(true), "a find's answers are not ranked: " & $v
    return asSubject(findAsked(v, resolve, how))
  let ranked = within.get(v.hasKind(RankedKind))
  let kind = compositeOf(v, ranked)
  if kind.isKind(bNil): return held(v, spaceBodies(v, ranked), ranked, how.skipRefused)
  guard kind != MergeKind or ranked, "a merge is of ranked searches: " & $v
  if kind == MoreKind:
    guard not ranked, "a more's answers are not ranked: " & $v
    return asSubject(interpret[Value, Value](v, how.skipRefused, resolve, how.followed))
  let lists = v.answers(PartsQ).toSeq
  guard lists.len > 0, "a composite with no parts said: " & $v
  # each list of parts joined as the kind joins them, and several lists so
  # too; a feed's first part answers what its second is asked
  var made: seq[Subject]
  for l in lists:
    guard l.isKind(bList, unmarked), "a composite's parts are a list: " & $l
    if kind == FeedKind:
      guard l.items.len == 2, "a feed has two parts: " & $l
      made.add fed(subjectOf(l.items[0], resolve, how, some false),
                   subjectOf(l.items[1], resolve, how, some ranked))
      continue
    made.add joined(kind, initStream(l.items.data).maps(subjectOf(it, resolve, how, some ranked)).toSeq)
  if made.len == 1: made[0]
  else: joined(if kind == FeedKind: AltKind else: kind, made)

proc rowsAsked(d: Value, asked: Option[Value], resolve: Search[Value, Value],
               how: Asking, subjects: seq[Subject] = @[]): Stream[Row] =
  ## the find `d`'s rows, its own names followed already
  let fd = Find.fromValue(d)
  let now = Asking(followed: how.followed + toBSet(identities(identityOf d)),
                   skipRefused: how.skipRefused)
  # bound first, and fd read again below: fed to initStream's sink seq
  # inside the call that also passes fd, fd.subjects was the compiler's
  # last read of fd and was moved out from under it (Nim 2.2.10)
  var found = initStream(fd.subjects).maps(subjectOf(it, resolve, now)).toSeq
  found.add subjects
  rows(fd, asked, found)

proc rows*(d: Value, asked = none(Value), resolve: Search[Value, Value] = nil,
           subjects: seq[Subject] = @[], skipRefused = false): Stream[Row] =
  ## every answer of the find `d`, asked `asked`, with the bindings it was
  ## written from and which part answered each clause: one per pull,
  ## nothing worked out ahead. What it asks of is its subjects, names among
  ## them found through `resolve` as they are needed, and `subjects` too.
  ## Refuses what isn't a find, and, as `fromValue` does, a subject it can't
  ## read, unless `skipRefused` passes over records a space can't hold
  rowsAsked(d, asked, resolve, Asking(followed: newBSet(), skipRefused: skipRefused), subjects)

proc findAsked(d: Value, resolve: Search[Value, Value], how: Asking):
    Search[Value, Value] =
  discard Find.fromValue(d)
  newSearch[Value, Value](q => rowsAsked(d, some q, resolve, how).maps(it.answer),
                          k(d), k(identityOf d))

proc findSearch*(d: Value, resolve: Search[Value, Value] = nil,
                 skipRefused = false): Search[Value, Value] =
  ## the search the find `d` stands for: asked, it answers as `rows` does,
  ## its asked holes bound to what it is asked. Written down, it is the find
  findAsked(d, resolve, Asking(followed: newBSet(), skipRefused: skipRefused))

proc search*(s: Shape, id = randomId()): Search[Value, Value] =
  ## the shape as a search, going by `id`: asked about a value, it answers
  ## every filling
  newSearch[Value, Value](v => s.fillings(v), id = id)
