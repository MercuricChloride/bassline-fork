## BVars: a place to put things and to search what has been put.
##
## A bvar is a send and a search over one place. It is not a register:
## it holds no "value of". The send takes a query and an answer, runtime
## things as readily as values, and says whether it took them; the
## search is how anything put is found, so every read asks something
## (nil when the asker gives nothing) and hands back a stream. Answers
## accumulate. Either half may be missing, and what a holder may do is
## just which halves it has.
##
## A bvar can be written down when its halves can, as an object (see
## `bl/queries/queries`) answering `send` and `search` with their
## denotations; a missing half is simply not answered:
##
##   !{!(kind bvar) (identity ID) (send SEND) (search SEARCH)}
##
## A space var holds a search set: what is sent is kept as a record
## (Q A), or (Q R A) for ranked answers, each turned into a value by its
## reading, and reading asks by Q. One with one answer a query holds a
## dict, where the first answer sent for a query stands: a new binding
## belongs in a new scope, not over an old one. Its send is written
## `!{!(kind send) !(to ID)}`, and a bvar pairing a space with a send to that
## same space reads back as a live space var.
##
## `persist` hands a bvar's space, written down, to anything that keeps
## values whenever it takes something; `bl/lib/bvarfile` keeps one in a
## file. `memo` keeps a search's answers in a bvar and answers from them
## first.

import std/[options, sets]
import ../core
import ./[search, send]
export search, send

refuseWith ValueError

type
  Access* {.pure.} = enum
    ## which halves a holder has
    none, r, w, rw

  BVar*[Q, A] = ref object
    sending: Send[Q, A]      ## nil for a holder who can't send
    reading: Search[Q, A]    ## nil for a holder who can't read
    identifying: proc(): Value

proc newBVar*[Q, A](send: Send[Q, A] = nil, read: Search[Q, A] = nil,
                    id = randomId()): BVar[Q, A] =
  ## a bvar whose sends go to `send` and whose reads ask `read`
  BVar[Q, A](sending: send, reading: read, identifying: k(id))

proc newBVar*[Q, A](send: proc(q: Q, a: A): bool, read: Search[Q, A] = nil,
                    id = randomId()): BVar[Q, A] =
  ## the same, its send made from a proc, with no denotation
  newBVar(newSend(send), read, id)

proc access*[Q, A](v: BVar[Q, A]): Access =
  ## what this holder can do, from the halves it has
  if v.sending != nil and v.reading != nil: Access.rw
  elif v.reading != nil: Access.r
  elif v.sending != nil: Access.w
  else: Access.none

proc canRead*[Q, A](v: BVar[Q, A]): bool =
  v.access in {Access.r, Access.rw}

proc canWrite*[Q, A](v: BVar[Q, A]): bool =
  v.access in {Access.w, Access.rw}

proc id*(v: BVar): Value =
  v.identifying()

proc send*[Q, A](v: BVar[Q, A], q: Q, a: A): bool =
  ## sends an answer for a query, saying whether it was taken; never
  ## taken by a holder who can't send
  v.sending != nil and v.sending.send(q, a)

proc sender*[Q, A](v: BVar[Q, A]): Send[Q, A] =
  ## the send half, to compose with other sends. Refuses a holder who
  ## can't send
  guard v.sending != nil, "this bvar can't be sent to here"
  v.sending

proc search*[Q, A](v: BVar[Q, A]): Search[Q, A] =
  ## the read half, to compose with other searches. Refuses a holder who
  ## can't read
  guard v.reading != nil, "this bvar is not readable here"
  v.reading

proc read*[Q, A](v: BVar[Q, A], q: Q): Stream[A] =
  ## asks the bvar about `q`
  v.search.ask(q)

proc `[]`*[Q, A](v: BVar[Q, A], q: Q): Stream[A] =
  ## asks the bvar about `q`: every answer, as a stream
  v.search.ask(q)

proc `?`*[Q, A](v: BVar[Q, A], q: Q): Option[A] =
  ## the first answer to `q`, for a consumer that wants just one
  v.search.ask(q)()

proc read*[Q, A](v: BVar[Q, A]): Stream[A] =
  ## asks the bvar with nothing in particular: Q's default, nil for a
  ## bvar asked in values
  v.search.ask(default(Q))

proc readOnly*[Q, A](v: BVar[Q, A]): BVar[Q, A] =
  ## the same place, for a holder who may only read it
  BVar[Q, A](sending: nil, reading: v.reading, identifying: v.identifying)

proc writeOnly*[Q, A](v: BVar[Q, A]): BVar[Q, A] =
  ## the same place, for a holder who may only send to it
  BVar[Q, A](sending: v.sending, reading: nil, identifying: v.identifying)

proc toValue*(v: BVar): Value =
  ## the bvar written down: the halves it has, by their denotations.
  ## Refuses a bvar with a half that has no denotation
  var halves: seq[Value]
  if v.sending != nil: halves.add initRec(@[SendQ, v.sending.toValue])
  if v.reading != nil: halves.add initRec(@[SearchQ, v.reading.toValue])
  describe([BVarKind], v.id, halves)

# ================ space vars ================

proc record[Q, A](q: Q, a: A): Value =
  ## the record a space keeps for an answer: (q a), or ranked (q r a)
  mixin toValue
  when A is Ranked:
    initRec(@[q.toValue, toValue(a.rank), a.answer.toValue])
  else:
    initRec(@[q.toValue, a.toValue])

proc spaceSend[Q, A](send: proc(q: Q, a: A): bool, id: Value): Send[Q, A] =
  newSend(send, k(sendTo(id)))

proc setVar[Q, A](held: BSet, id: Value, skipRefused: bool): BVar[Q, A] =
  ## a space var over a set: every answer sent is kept
  proc send(q: Q, a: A): bool =
    held.incl record(q, a)
    true
  newBVar(spaceSend[Q, A](send, id), searchOver[Q, A](held, id, skipRefused), id)

proc dictVar[Q, A](held: BDict, id: Value, skipRefused: bool): BVar[Q, A] =
  ## a space var over a dict: the first answer sent for a query stands
  mixin toValue
  proc send(q: Q, a: A): bool =
    let (query, answer) = (q.toValue, a.toValue)
    if query in held: return held[query] == answer
    held[query] = answer
    true
  newBVar(spaceSend[Q, A](send, id), searchOver[Q, A](held, id, skipRefused), id)

proc spaceVar*[Q, A](fanout = many, id = randomId(), skipRefused = false):
    BVar[Q, A] =
  ## a bvar holding an empty search set in memory, going by `id`
  when A is Ranked:
    guard fanout == many, "a ranked search has any number of answers"
    setVar[Q, A](newBSet(), id, skipRefused)
  else:
    if fanout == one: dictVar[Q, A](newBDict(), id, skipRefused)
    else: setVar[Q, A](newBSet(), id, skipRefused)

proc spaceVar*[Q, A](space: Value, skipRefused = false): BVar[Q, A] =
  ## a bvar holding a copy of a denoted space, everything it holds, by
  ## the space's own names: a dict, one answer a query, if it holds one
  ## dict, and otherwise a set of every record it holds. Refuses anything
  ## else
  guard space.isObject and space.hasKind(SearchSpaceKind),
    "not a search space: " & $space
  guard compositeOf(space, A is Ranked).kind == bNil,
    "a composite holds nothing itself: " & $space
  let bodies = spaceBodies(space, A is Ranked)
  let id = identityOf(space)
  if bodies.len == 1 and bodies[0].kind == bDict:
    when A isnot Ranked:   # a ranked space holds only sets
      return dictVar[Q, A](bodies[0].dict + newBDict(), id, skipRefused)
  let records = initStream(bodies).flatMap(proc(b: Value): Stream[Value] =
    if b.kind == bSet: b.members
    else: b.entries.map((Value, Value) -> initRec(@[it[0], it[1]])))
  setVar[Q, A](toBTreeSet(collect(records)), id, skipRefused)

# ================ reading a bvar back ================

proc uniqueRefs[T: ref](s: Stream[T]): Stream[T] =
  ## `s`, each object once
  var seen = initHashSet[pointer]()
  s.filter(proc(x: T): bool =
    result = not seen.containsOrIncl(cast[pointer](x)))

proc fromValue*[Q, A](T: typedesc[BVar[Q, A]], d: Value,
                      resolveSend: Search[Value, Send[Q, A]] = nil,
                      resolve: Search[Value, Value] = nil,
                      skipRefused = false): BVar[Q, A] =
  ## the bvar a denotation stands for here. Every send it answers is
  ## told, and every search it answers is asked, in turn. A send reaches,
  ## for each name of each thing it sends to, whatever sends `resolveSend`
  ## answers for that name when something is sent; a plain space the
  ## bvar also answers as its search is held here as a live copy, which
  ## answers for the space's names as well. Searches are read through
  ## `resolve`. A half not answered is missing
  guard d.isObject and d.hasKind(BVarKind), "not a bvar: " & $d
  let id = identityOf(d)
  let isPlainSpace = proc(r: Value): bool =
    r.hasKind(SearchSpaceKind) and compositeOf(r, A is Ranked).kind == bNil
  var
    copies: seq[(Value, BVar[Q, A])]   # plain spaces held live, by their names
    searches: seq[Search[Q, A]]
  for r in d.answers(SearchQ):
    if r.isPlainSpace:
      let live = spaceVar[Q, A](r, skipRefused)
      copies.add (identityOf(r), live)
      searches.add live.reading
    else:
      searches.add Search[Q, A].fromValue(r, skipRefused, resolve)
  let sends = collect(d.answers(SendQ).map(proc(s: Value): Value =
    guard s.isObject and s.hasKind(SendKind), "not a send: " & $s
    s))
  var sending: Send[Q, A] = nil
  if sends.len > 0:
    let ids = collect(initStream(sends).flatMap(targets))
    proc reaching(t: Value): Stream[Send[Q, A]] =
      # the live copies going by a name of t, then whatever sends the
      # environment has for each of its names, by now
      let held = initStream(copies)
        .filter(proc(c: (Value, BVar[Q, A])): bool = sharesIdentity(t, c[0]))
        .map(proc(c: (Value, BVar[Q, A])): Send[Q, A] = c[1].sending)
      if resolveSend == nil: return held
      cat(held, identities(t).flatMap(proc(n: Value): Stream[Send[Q, A]] =
        resolveSend.ask(n)))
    proc send(q: Q, a: A): bool =
      initStream(ids).flatMap(reaching).uniqueRefs.collect.tee.send(q, a)
    sending = newSend(send, k(sendTo(ids)))
  let reading =
    if searches.len == 0: nil
    elif searches.len == 1: searches[0]
    else: alt(searches, id)
  newBVar(sending, reading, id)

# ================ keeping a bvar ================

proc persist*[Q, A](v: BVar[Q, A], keep: proc(space: Value): bool):
    BVar[Q, A] =
  ## the same place, handing its space, written down, to `keep` each
  ## time it takes something. Refuses a place that can't be both sent to
  ## and written down here
  let inner = v.sender
  let space = v.search
  guard space.denotable, "this bvar's space can't be written down"
  proc send(q: Q, a: A): bool =
    # taken means kept: a send the keeper couldn't keep answers no, though
    # the place holds it all the same, and the next keep writes it
    inner.send(q, a) and keep(space.toValue)
  var denote: proc(): Value = nil
  if inner.denotable: denote = proc(): Value = inner.toValue
  newBVar(newSend(send, denote), v.reading, v.id)

# ================ many places as one ================

proc union*[Q, A](parts: openArray[BVar[Q, A]], id = randomId()): BVar[Q, A] =
  ## many places as one: a send tells every part that can be sent to,
  ## taken if any took it, and a read asks every part that can be read,
  ## their answers taking turns. A primary resolver is this, over many
  var 
    sends: seq[Send[Q, A]]
    reads: seq[Search[Q, A]]
  for each in parts:
    if each.canWrite: sends.add each.sender
    if each.canRead: reads.add each.search
  newBVar(if sends.len == 0: nil else: tee(sends),
          if reads.len == 0: nil else: alt(reads, id), id)

# ================ memoising ================

proc memo*[Q, A](s: Search[Q, A], kept: BVar[Q, A]): Search[Q, A] =
  ## `s`, answering first from what `kept` holds and then with what `s`
  ## finds that it doesn't, each new answer sent to `kept` as it is
  ## pulled; ranked, the two merged by rank. Each answer is given once. A
  ## search with one answer a query isn't asked again once `kept` has its
  ## answer, since the memo stops at its first. Written down, it is what
  ## `kept` holds
  proc ask(q: Q): Stream[A] =
    let given = newBSet()
    proc firstTime(a: A): bool =
      let r = record(q, a)
      result = r notin given
      if result: given.incl r
    let fresh = lazy(proc(): Stream[A] =
      s.ask(q)
        .filter(proc(a: A): bool = record(q, a) notin given)
        .tap(proc(a: A) = discard kept.send(q, a)))
    when A is Ranked: byRank(kept[q], fresh).filter(firstTime)
    else: cat(kept[q], fresh).filter(firstTime)
  newSearch[Q, A](ask, proc(): Value = kept.search.toValue,
                  proc(): Value = kept.search.id, s.fanout)

proc memo*[Q, A](s: Search[Q, A], id = randomId()): Search[Q, A] =
  ## `s`, memoised in memory: a set of records, or for a search with one
  ## answer a query, a dict
  s.memo(spaceVar[Q, A](s.fanout, id))
