## Searches: what you ask, handing back a stream you pull.
##
## A search closes over whatever it answers from; how it got there is
## its own construction. Searches compose into new searches: one after
## another (`cat`, as a scope falls back to the scope around it), taking
## turns (`alt`), answers fed on as questions (`feed`), ranked answers
## merged by rank (`merge`).
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
## and `alt`, `feed` and `merge` like `cat`; R is a natural, and a part
## is an object, or names of a thing written down elsewhere.
##
## A one-field record (Q) in a space is a question, Q being asked, not
## an answer; it sorts after Q's answers, so a query's run holds both,
## and answering passes over it. A record's head is the query, so CE
## order keeps one query's records together, and in a ranked space puts
## them in rank order.
##
## A part may be a whole object, or only names (an object with no kind,
## or any other value): a scope's denotation can carry the scope around
## it whole, or name it, and interpreting a name asks a search of known
## spaces about each of its names.

import std/options
import ../core
import ./[queries, stream]
export queries, stream

refuseWith ValueError

type
  Fanout* = enum
    ## how many answers a query may have: any number, as a set of records
    ## holds them, or at most one, as a dict does
    many, one

  Search*[Q, A] = ref object
    fanning: Fanout
    asking: proc(q: Q): Stream[A]
    denoting: proc(): Value     ## nil for a search with no denotation
    identifying: proc(): Value  ## the ID it goes by, without writing it down

  Ranked*[A] = object
    ## an answer from a ranked search, and where it ranks: lowest first
    rank*: Natural
    answer*: A

proc atMostOne[Q, A](ask: proc(q: Q): Stream[A]): proc(q: Q): Stream[A] =
  ## `ask`, its streams stopping after their first answer
  proc(q: Q): Stream[A] =
    let s = ask(q)
    var given = false
    proc(): Option[A] =
      if given: return none A
      result = s()
      given = true

proc newSearch*[Q, A](ask: proc(q: Q): Stream[A],
                      denote: proc(): Value = nil,
                      id: proc(): Value = nil,
                      fanout = many): Search[Q, A] =
  ## a search that answers with `ask`, that writes its space down with
  ## `denote` if it can, and says what ID it goes by with `id`. With
  ## `fanout = one` a query has at most one answer, as from a dict
  Search[Q, A](fanning: fanout, denoting: denote, identifying: id,
               asking: if fanout == one: atMostOne(ask) else: ask)

proc newSearch*[Q, A](ask: proc(q: Q): Stream[A],
                      denote: proc(): Value = nil, id: Value,
                      fanout = many): Search[Q, A] =
  ## the same, going by the ID `id`
  newSearch(ask, denote, k(id), fanout)

proc writtenAs[Q, A](s: Search[Q, A], denote, id: proc(): Value):
    Search[Q, A] =
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
  identityOf(s.toValue)

proc byId*[Q, A](s: Search[Q, A]): Search[Q, A] =
  ## `s`, written down by its ID alone: a composite that holds it names
  ## it rather than carrying it whole
  let name = proc(): Value = s.id
  s.writtenAs(name, name)

proc byRank*[R: Ranked](streams: varargs[Stream[R]]): Stream[R] =
  ## ranked streams, each in rank order, merged by rank, lowest first; on
  ## a tie the earlier stream goes first
  merge(proc(a, b: R): int = cmp(a.rank, b.rank), streams)

# ================ composing ================

proc denoteParts[A](kind, id: Value, parts: seq[Value]): Value =
  ## a composite written down: a search space of its kind, ranked when its
  ## answers are
  let ks = when A is Ranked: @[SearchSpaceKind, kind, RankedKind]
           else: @[SearchSpaceKind, kind]
  describe(ks, id, initRec(@[PartsQ, initList(parts)]))

proc partsDenoter[Q, A](kind, id: Value, parts: seq[Search[Q, A]]):
    proc(): Value =
  ## a composite's denotation, if every part has one
  if not initStream(parts).every(proc(p: Search[Q, A]): bool = p.denotable):
    return nil
  proc(): Value =
    denoteParts[A](kind, id,
      collect(initStream(parts).map(proc(p: Search[Q, A]): Value = p.toValue)))

proc cat*[Q, A](parts: openArray[Search[Q, A]], id = randomId()):
    Search[Q, A] =
  ## each part's answers in turn, a part asked only once the one before
  ## it has nothing more: a scope, then the scope around it
  let ps = @parts
  proc ask(q: Q): Stream[A] =
    initStream(ps).flatMap(proc(p: Search[Q, A]): Stream[A] = p.ask(q))
  newSearch[Q, A](ask, partsDenoter(CatKind, id, ps), k(id))

proc asked[Q, A](ps: seq[Search[Q, A]], q: Q): seq[Stream[A]] =
  ## each part's stream for `q`
  collect(initStream(ps).map(proc(p: Search[Q, A]): Stream[A] = p.ask(q)))

proc alt*[Q, A](parts: openArray[Search[Q, A]], id = randomId()):
    Search[Q, A] =
  ## the parts' answers taking turns, so no part starves the others
  let ps = @parts
  proc ask(q: Q): Stream[A] = alt(ps.asked(q))
  newSearch[Q, A](ask, partsDenoter(AltKind, id, ps), k(id))

proc feed*[Q, M, A](first: Search[Q, M], then: Search[M, A],
                    id = randomId()): Search[Q, A] =
  ## each answer of `first` asked of `then`, their streams taking turns
  ## as they arrive
  proc ask(q: Q): Stream[A] =
    altFrom(first.ask(q).map(proc(m: M): Stream[A] = then.ask(m)))
  let denote =
    if first.denotable and then.denotable:
      proc(): Value = denoteParts[A](FeedKind, id, @[first.toValue, then.toValue])
    else: nil
  newSearch[Q, A](ask, denote, k(id),
                  if first.fanout == one and then.fanout == one: one else: many)

proc merge*[Q; R: Ranked](parts: openArray[Search[Q, R]], id = randomId()):
    Search[Q, R] =
  ## ranked parts' answers merged by rank, lowest first; on a tie the
  ## earlier part goes first
  let ps = @parts
  proc ask(q: Q): Stream[R] = byRank(ps.asked(q))
  newSearch[Q, R](ask, partsDenoter(MergeKind, id, ps), k(id))

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
  v.kind == bNum and not v.mark and v.num.isInt and v.num.toInt >= 0

proc readBack[A](records: Stream[Value], ranked, skipRefused: bool):
    Stream[A] =
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
      refuse "not a (query " & (if ranked: "rank " else: "") &
             "answer) record: " & $r
  proc read(r: Value): Option[A] =
    when A is Ranked:
      let a = reading[typeof(default(A).answer)](r.items[2], skipRefused)
      if a.isSome: some A(rank: r.items[1].num.toInt, answer: a.get) else: none(A)
    else:
      reading[A](r.items[^1], skipRefused)
  records.filter(held).filterMap(read)

proc setAsk[Q, A](els: BSet, skipRefused: bool): proc(q: Q): Stream[A] =
  ## asking a set of records: those headed by the query, read back
  mixin toValue
  proc(q: Q): Stream[A] =
    readBack[A](els.headed(q.toValue), A is Ranked, skipRefused)

proc dictAsk[Q, A](d: BDict, skipRefused: bool): proc(q: Q): Stream[A] =
  ## asking a dict: the query's one answer, if it has one, read back
  mixin toValue
  proc(q: Q): Stream[A] =
    let query = q.toValue
    if query notin d: return empty[A]()
    readBack[A](just(initRec(@[query, d[query]])), false, skipRefused)

proc spaceKinds[A](): seq[Value] =
  when A is Ranked: @[SearchSpaceKind, RankedKind] else: @[SearchSpaceKind]

proc searchOver*[Q, A](space: BSet, id: Value, skipRefused = false):
    Search[Q, A] =
  ## a search over a set of records held now, which may still grow: each
  ## ask sees it as it stands, and a stream keeps seeing what is added
  ## past where it has got to. Written down, it is a copy of the set as
  ## it stands then, so the value never changes after
  let copied = proc(): Value =
    describe(spaceKinds[A](), id, initRec(@[HoldsQ, initSet(space + newBSet())]))
  newSearch[Q, A](setAsk[Q, A](space, skipRefused), copied, k(id), many)

proc searchOver*[Q, A](space: BDict, id: Value, skipRefused = false):
    Search[Q, A] =
  ## a search over a dict held now: one answer a query, and the same
  ## copy taken to write it down
  when A is Ranked:
    {.error: "a ranked search has any number of answers, so no dict".}
  let copied = proc(): Value =
    describe([SearchSpaceKind], id, initRec(@[HoldsQ, initDict(space + newBDict())]))
  newSearch[Q, A](dictAsk[Q, A](space, skipRefused), copied, k(id), one)

proc compositeOf*(d: Value, ranked: bool): Value =
  ## how a search space's parts are read, nil for a space that holds its
  ## answers itself. Each kind says its own part: `search-space` that it
  ## is a search, `ranked` that its answers are ranked, and a composite
  ## kind how its parts are read. Refuses a kind it can't carry out, two
  ## ways of reading the parts at once, and a space ranked otherwise than
  ## `ranked`
  let composites = [CatKind, AltKind, FeedKind, MergeKind]
  let unread = d.kinds.filter(Value ->
    it notin composites and it != SearchSpaceKind and it != RankedKind)[]
  guard unread.isNone, "a kind this doesn't read, " & $unread.get & ", in " & $d
  guard d.hasKind(RankedKind) == ranked,
    (if ranked: "an unranked space, read as ranked: "
     else: "a ranked space, read as unranked: ") & $d
  let found = d.kinds.filter(Value -> it in composites).take(2)
  guard found.len < 2, "a search space read as two composites: " & $d
  if found.len == 1: found[0] else: null()

proc spaceBodies*(d: Value, ranked: bool): seq[Value] =
  ## everything a denoted space holds: every `holds` answer, each a set of
  ## records or, unranked, a dict. Refuses a space holding nothing, and a
  ## body it can't hold
  result = collect(d.answers(HoldsQ).map(proc(b: Value): Value =
    guard (b.isKind({bSet}) or (not ranked and b.isKind({bDict}))) and not b.mark,
      "a space holds sets of records" & (if ranked: "" else: " or dicts") &
      ": " & $d
    b))
  guard result.len > 0, "a space that holds nothing said: " & $d

proc bodyAsk[Q, A](b: Value, skipRefused: bool): proc(q: Q): Stream[A] =
  ## asking one body a denoted space holds
  when A is Ranked: setAsk[Q, A](b.els, skipRefused)
  else:
    if b.kind == bDict: dictAsk[Q, A](b.dict, skipRefused)
    else: setAsk[Q, A](b.els, skipRefused)

proc space[Q, A](d: Value, skipRefused: bool): Search[Q, A] =
  ## the search a denoted space stands for, answering from every body it
  ## holds: in turn, or merged by rank when its answers are ranked. One
  ## answer a query only when it holds one dict
  let bodies = spaceBodies(d, A is Ranked)
  proc ask(q: Q): Stream[A] =
    let streams = collect(initStream(bodies).map(proc(b: Value): Stream[A] =
      bodyAsk[Q, A](b, skipRefused)(q)))
    when A is Ranked: byRank(streams) else: cat(streams)
  newSearch[Q, A](ask, k(d), k(identityOf(d)),
                  if bodies.len == 1 and bodies[0].kind == bDict: one else: many)

proc interpret[Q, A](d: Value, skipRefused: bool,
                     resolve: Search[Value, Value], followed: BSet):
    Search[Q, A]

proc named[Q, A](name: Value, skipRefused: bool,
                 resolve: Search[Value, Value], followed: BSet):
    Search[Q, A] =
  ## the search a name stands for: asked, it asks `resolve` about each
  ## name, as things stand then, and answers from each space found in
  ## turn, once however many names find it. A name already followed on
  ## the way here is passed over, so names that lead round to themselves
  ## come to an end. Written down, it is the name again
  guard resolve != nil, "names a space, with nothing to resolve it: " & $name
  proc ask(q: Q): Stream[A] =
    let fresh = collect(identities(name).filter(Value -> it notin followed))
    let now = followed + toBTreeSet(fresh)
    initStream(fresh)
      .flatMap(Value -> resolve.ask(it))
      .unique
      .flatMap(proc(d: Value): Stream[A] =
        interpret[Q, A](d, skipRefused, resolve, now).ask(q))
  newSearch[Q, A](ask, k(name), k(name))

proc combine[Q, A](kind: Value, ps: seq[Search[Q, A]], id: Value):
    Search[Q, A] =
  ## searches joined as a composite of `kind` joins its parts: one after
  ## another for a cat, merged by rank for a merge, and otherwise taking
  ## turns, as an alt's parts do and a feed's streams do
  when A is Ranked:
    if kind == MergeKind: return merge(ps, id)
  if kind == CatKind: cat(ps, id) else: alt(ps, id)

proc composite[Q, A](kind, parts, id: Value, skipRefused: bool,
                     resolve: Search[Value, Value], followed: BSet):
    Search[Q, A] =
  ## the composite one list of parts stands for
  guard parts.kind == bList and not parts.mark,
    "a composite's parts are a list: " & $parts
  if kind == FeedKind:
    guard parts.items.len == 2, "a feed has two parts: " & $parts
    return feed(
      interpret[Q, Value](parts.items[0], skipRefused, resolve, followed),
      interpret[Value, A](parts.items[1], skipRefused, resolve, followed), id)
  combine(kind, collect(initStream(parts.items.data).map(proc(p: Value): Search[Q, A] =
    interpret[Q, A](p, skipRefused, resolve, followed))), id)

proc interpret[Q, A](d: Value, skipRefused: bool,
                     resolve: Search[Value, Value], followed: BSet):
    Search[Q, A] =
  ## the search `d` stands for, `followed` the names already followed on
  ## the way to it
  if not d.hasKind(SearchSpaceKind):
    guard d.kinds[].isNone, "neither a search nor names of one: " & $d
    return named[Q, A](d, skipRefused, resolve, followed)
  let kind = compositeOf(d, A is Ranked)
  if kind.kind == bNil:
    return space[Q, A](d, skipRefused)
  guard kind != MergeKind or A is Ranked, "a merge is of ranked searches: " & $d
  let id = identityOf(d)
  let made = collect(d.answers(PartsQ).map(proc(parts: Value): Search[Q, A] =
    composite[Q, A](kind, parts, id, skipRefused, resolve, followed)))
  guard made.len > 0, "a composite with no parts said: " & $d
  let whole = if made.len == 1: made[0] else: combine(kind, made, id)
  whole.writtenAs(k(d), k(id))

proc fromValue*[Q, A](T: typedesc[Search[Q, A]], d: Value,
                      skipRefused = false,
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