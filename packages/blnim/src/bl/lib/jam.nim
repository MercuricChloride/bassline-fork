## jam: a place to put answers and ask questions, shared at the edge.
##
## The convention is the arity one search spaces already keep:
##
##   (Q A)   puts A as an answer to the question Q
##   (Q)     asks Q
##
## A jam keeps every answer put to it under its question, ranked by when
## it heard it, and tells each line that asks Q the record (Q R A) for
## every answer to Q: those it has, then each as it comes. R is the jam's
## own order, so a reader can tell what it has been told; an answer put
## twice is kept once. What a question or an answer means is for those
## who ask and put: the jam reads neither.
##
## Signed values from `bl clave`, (signed (Q A) SIGNATURE) and
## (signed (Q) SIGNATURE), are taken as what they sign, and an answer that
## came signed is kept signed, so whoever is told it can check who said it
## and that they said it to Q. A jam that takes only signed values refuses
## anything else; any jam refuses a signature that doesn't hold.
##
## The jam says two things itself. It answers (jam) with which jam it
## is, !{(identity NAME) (identity ID) (at MS)}: the name it goes by,
## sixteen random bytes and when it began, put once, the first time it
## opens its log, so a jam opened on that log again is the same jam and
## a reader dialling a place can tell whether the jam there is the one
## it was told by. A line may ask (jam) and not put to it. And once
## nothing more will arrive on a line, or it can no longer reach it, it
## puts (gone !{(by ID) (at MS)}) for each (here !{(by ID) …}) that line
## put. A jam opened on a log puts it for everyone the log says is here,
## since no line reaches them yet.
##
## What people and programs share on top, which a jam needs none of:
##
## - a room is a question, and a message is an answer to it, an object
##   answering `by`, `said` and `at`, and maybe `re` (the digest of what it
##   answers) and `for` (whom it is for):
##     (general !{(by alice) (said "hi all") (at 1759500000000)})
##   `said` is any value: text for people, anything for programs.
## - a person's own room is (for NAME): what is said there is for them.
##   A message (for all) is for everyone who hears the room it is said in.
## - (here !{(by ID) (at MS)}) says someone is listening, and gone that
##   they have stopped; (rooms ROOM) lists a room.
## - an ID is a name, or an object of names, a key among them for
##   whoever signs: !{(identity alice) (identity 0x…)}.
##
## A jam given a key keeps its order as a tea-time order
## (`bl/lib/teatime`). It goes by a name and that key, says so in its own
## (here !{(by ID) (at MS) (stamps (stamps NAME))}), and for every answer
## it keeps puts under (stamps NAME) its reflector's next message, signed:
## (tea-msg R T PREV (Q D)), that it heard the answer whose digest is D
## (the digest `re` names) for Q at rank R, the message's ordinal, at T by
## its own clock, PREV the digest of the message before. A stamp is told
## at the rank it stamps, so stamps take no ranks of their own and nothing
## stamps a stamp, and what is under (stamps NAME) is the jam's own: a
## line may ask it and not put to it. Which key is a jam's is each
## reader's own knowledge.
##
## So a reader's knowledge is its own ranked space of what it has been
## told, and what it shows are searches over it.

import std/[algorithm, options, sequtils, sysrand]
import ../[core, queries]
import ./teatime
import ./crypto/[clave, digest]
export teatime

refuseWith BasslineError

let
  JamQ* = sym"jam"      ## which jam this is
  HereQ* = sym"here"    ## who is listening
  GoneQ* = sym"gone"    ## who has stopped
  RoomsQ* = sym"rooms"  ## rooms someone has opened
  ForQ* = sym"for"      ## whom a message is for; (for NAME) is their room
  AllName* = sym"all"   ## whom a message for everyone who hears it is for
  ByQ* = sym"by"        ## who says
  SaidQ* = sym"said"    ## what
  ReQ* = sym"re"        ## the digest of what it answers
  AtQ* = sym"at"        ## when, by the speaker's clock, in milliseconds
  StampsQ* = sym"stamps"  ## (stamps NAME): where a jam named NAME puts its stamps
  SignedHead = sym"signed"

proc opened*(v: Value): Option[tuple[said: Value, signer: Option[Key]]] =
  ## what a value says, and the key that signed it if it came signed:
  ## (signed V SIGNATURE) says V when the signature holds, and nothing
  ## when it doesn't; anything else says itself
  type Said = tuple[said: Value, signer: Option[Key]]
  if v.isKind(bRec, unmarked) and v.items.len == 3 and v.head == SignedHead:
    let s = try: Signed.fromValue(v) except ValueError: return none(Said)
    if not s.holds: return none(Said)
    return some (s.value, some s.sig.pubkey)
  some (v, none(Key))

# ================ the jam ================

type
  JamLine* = ref object
    ## a line to the jam: the send that tells it, and who it said is here
    tell: (Value) -> bool
    heres: seq[Value]
    open: bool

  Asking = object
    ## a line's question
    q: Value
    line: JamLine

  Jam* = ref object
    log: BVar[Value, Ranked[Value]]  ## what was put, ranked by when heard
    kept: Value                      ## every (Q A) kept, a set, so each once
    next: int                        ## the rank the next answer gets
    signedOnly: bool
    askings: seq[Asking]
    reflector: Reflector             ## signs its stamps; nil for a jam that doesn't
    stampsQ: Value                   ## where it puts them

proc who*(local: BVar[Value, Ranked[Value]]): seq[Value]
proc put(jam: Jam, line: JamLine, q, kept, said: Value): bool

proc presence(id: Value, at: int64): Value =
  obj(initRec(@[ByQ, id]), initRec(@[AtQ, toValue(at)]))

proc stamp(jam: Jam, q, kept: Value, rank: int): Ranked[Value] =
  ## keeps the reflector's word that it heard `kept` for `q`: its next
  ## message, whose ordinal is `rank`, put at that rank. The reflector has
  ## spoken once it signs, so a keeper that refuses the stamp leaves an
  ## order that can't be kept, and is refused
  doAssert jam.reflector.next == rank, "a jam's ranks and its reflector's ordinals run together"
  let signed = jam.reflector.sign(initRec(@[q, digest(kept, Blake2bAlgo).toValue])).toValue
  result = Ranked[Value](rank: rank, answer: signed)
  guard jam.log.send(jam.stampsQ, result), "the jam's keeper refused its stamp for rank " & $rank
  jam.kept.incl initRec(@[jam.stampsQ, signed])

proc newJam*(log: BVar[Value, Ranked[Value]], signedOnly = false,
             key = none(Keypair), name = sym"jam"): Jam =
  ## a jam keeping what is put in `log`, which may hold some already,
  ## and which jam it is with it; a log holding none is a jam beginning,
  ## going by `name`. Whoever it says is here is gone: no line reaches
  ## them yet. Given a key, it stamps what it keeps, going by `name` and
  ## the key, its order going on from the stamps the log holds; a log
  ## whose ranks that key hasn't all stamped, once each and in one
  ## chain, is refused
  result = Jam(log: log, kept: initSet(), signedOnly: signedOnly,
               stampsQ: initRec(@[StampsQ, name]))
  let jam = result
  for r in log.search.toValue.answers(HoldsQ).flatMaps(it.members):
    jam.kept.incl initRec(@[r.items[0], r.items[2]])
    jam.next = max(jam.next, r.items[1].num.toInt + 1)
  if key.isSome:
    var history = initHistory(key.get.pubkey)
    for r in log[jam.stampsQ]:
      let o = opened(r.answer)
      if o.isSome and o.get.signer == some(key.get.pubkey):
        discard history.add Signed.fromValue(r.answer)
    jam.reflector = initReflector(key.get, history)
    guard history.conflicts.len == 0 and history.hasAll and jam.reflector.next == jam.next,
      "a jam stamps every rank from its first, once: this log's aren't all stamped by this key"
  if (log ? JamQ).isNone:
    let me = obj(initRec(@[IdentityQ, name]), initRec(@[IdentityQ, bytes(urandom(16))]),
                 initRec(@[AtQ, toValue(now())]))
    discard jam.put(nil, JamQ, me, me)
  for id in who(log):
    let gone = presence(id, now())
    discard jam.put(nil, GoneQ, gone, gone)
  if jam.reflector != nil:
    let me = identity(name, bytes(@(jam.reflector.key)))
    let here = obj(initRec(@[ByQ, me]), initRec(@[AtQ, toValue(now())]),
                   initRec(@[StampsQ, jam.stampsQ]))
    discard jam.put(nil, HereQ, jam.reflector.keypair.signed(initRec(@[HereQ, here])).toValue, here)

proc newLine*(jam: Jam, tell: (Value) -> bool): JamLine =
  ## a line that `tell` tells
  JamLine(tell: tell, open: true)

proc drop*(jam: Jam, line: JamLine)

proc told(q: Value, r: Ranked[Value]): Value =
  ## an answer to `q` as a line is told it, (Q R A)
  initRec(@[q, toValue(r.rank), r.answer])

proc tell(jam: Jam, q: Value, r: Ranked[Value]) =
  ## every line asking `q` told an answer just kept; a line that refuses
  ## is dropped
  for a in jam.askings.filterIt(it.q == q):
    if a.line.open and not a.line.tell(told(q, r)): jam.drop(a.line)

proc put(jam: Jam, line: JamLine, q, kept, said: Value): bool =
  ## keeps `kept` as an answer to `q`, `said` being what it says
  if initRec(@[q, kept]) notin jam.kept.els:
    let r = Ranked[Value](rank: jam.next, answer: kept)
    if not jam.log.send(q, r): return false
    jam.kept.incl initRec(@[q, kept])
    let stamping = jam.reflector != nil and q != jam.stampsQ
    let stamped = if stamping: jam.stamp(q, kept, r.rank) else: Ranked[Value]()
    inc jam.next
    jam.tell(q, r)
    if stamping: jam.tell(jam.stampsQ, stamped)
  if q == HereQ and line != nil:
    let id = said.answer(ByQ)
    if id.isSome and id.get notin line.heres: line.heres.add id.get
  true

proc ask(jam: Jam, line: JamLine, q: Value): bool =
  ## tells the line every answer to `q` it has, and then each as it is
  ## kept
  if jam.askings.anyIt(it.line == line and it.q == q): return true
  for r in jam.log[q]:
    if not line.tell(told(q, r)):
      jam.drop(line)
      return true
  if line.open: jam.askings.add Asking(q: q, line: line)
  true

proc hear*(jam: Jam, line: JamLine, v: Value): bool =
  ## a value arriving on a line: an answer to keep or a question to
  ## answer, answering whether it was taken
  let o = opened(v)
  if o.isNone or (jam.signedOnly and o.get.signer.isNone): return false
  let said = o.get.said
  if not said.isKind(bRec, unmarked) or not line.open: return false
  case said.items.len
  of 1: jam.ask(line, said.items[0])
  of 2:
    if said.items[0] == JamQ or (jam.reflector != nil and said.items[0] == jam.stampsQ):
      return false
    let kept = if o.get.signer.isSome: v else: said.items[1]
    jam.put(line, said.items[0], kept, said.items[1])
  else: false

proc leave(jam: Jam, line: JamLine) =
  ## puts that whoever the line said was here is gone
  let ids = line.heres
  line.heres.setLen 0
  for id in ids:
    let gone = presence(id, now())
    discard jam.put(nil, GoneQ, gone, gone)

proc drop*(jam: Jam, line: JamLine) =
  ## the line can no longer be reached: it is told nothing more, and
  ## whoever it said was here is gone
  if not line.open: return
  line.open = false
  jam.askings.keepItIf(it.line != line)
  jam.leave(line)

proc quiet*(jam: Jam, line: JamLine): bool =
  ## nothing more will arrive on the line: whoever it said was here is
  ## gone, since a line stops speaking when its speaker leaves, and it is
  ## told on while it asks anything (a pipe may stop speaking and go on
  ## hearing). Answers whether to keep telling it
  jam.leave(line)
  result = jam.askings.anyIt(it.line == line)
  if not result: jam.drop(line)

# ================ readers ================

type
  Heard* = object
    ## an answer as a jam told it
    q*: Value               ## the question it answers
    rank*: int              ## where the jam heard it
    answer*: Value          ## as put: the answer, or the signed (Q A)
    said*: Value            ## the answer itself
    signer*: Option[Key]    ## the key that signed it, if it came signed

  Speaker* = object
    ## someone speaking to a jam: the name they go by, and a key to sign
    ## with, if they sign
    name*: Value
    key*: Option[Keypair]

proc heard*(record: Value): Option[Heard] =
  ## (Q R A) as a jam tells it. An answer that came signed is passed over
  ## unless its signature holds and it answers this question, or is a
  ## reflector's own message, (tea-msg …), which says what it is
  if not record.isKind(bRec) or record.items.len != 3: return none(Heard)
  let (q, r, a) = (record.items[0], record.items[1], record.items[2])
  if not r.isKind(bNum, unmarked) or not r.num.isInt or r.num.toInt < 0: return none(Heard)
  let o = opened(a)
  if o.isNone: return none(Heard)
  var h = Heard(q: q, rank: r.num.toInt, answer: a, said: a)
  if o.get.signer.isSome:
    let inner = o.get.said
    if TeaMsg.fits(inner): h.said = inner
    elif inner.isKind(bRec) and inner.items.len == 2 and inner.items[0] == q: h.said = inner.items[1]
    else: return none(Heard)
    h.signer = o.get.signer
  some h

proc keep*(local: BVar[Value, Ranked[Value]], record: Value): Option[Heard] =
  ## keeps what a jam told in a reader's own ranked space, answering what
  ## it heard, or nothing for a record it can't read
  result = heard(record)
  if result.isSome:
    discard local.send(result.get.q,
                       Ranked[Value](rank: result.get.rank, answer: result.get.answer))

proc heardIn*(local: BVar[Value, Ranked[Value]], q: Value): Stream[Heard] =
  ## what a reader has been told answers `q`, in the order the jam heard it
  local[q].filterMaps heard(initRec(@[q, toValue(it.rank), it.answer]))

proc by*(s: Speaker): Value =
  ## who a speaker says they are: their name, and their key if they sign
  if s.key.isNone: s.name
  else: identity(s.name, bytes(@(s.key.get.pubkey)))

proc spoken(s: Speaker, v: Value): Value =
  if s.key.isNone: v else: s.key.get.signed(v).toValue

proc put*(s: Speaker, q, a: Value): Value =
  ## the value that puts `a` as an answer to `q`, signed if `s` signs
  s.spoken initRec(@[q, a])

proc ask*(s: Speaker, q: Value): Value =
  ## the value that asks `q`, signed if `s` signs
  s.spoken initRec(@[q])

proc message*(s: Speaker, said: Value, re: openArray[Value] = [],
              `for`: openArray[Value] = []): Value =
  ## a message from `s` saying `said`, now
  var members = @[initRec(@[ByQ, s.by]), initRec(@[SaidQ, said]),
                  initRec(@[AtQ, toValue(now())])]
  for d in re: members.add initRec(@[ReQ, d])
  for n in `for`: members.add initRec(@[ForQ, n])
  obj members

proc isFor*(said, id: Value): bool =
  ## whether a message is for someone going by `id`: it names one of
  ## their names as whom it is for, or names all
  said.answers(ForQ).exists(n => n == AllName or sharesIdentity(n, id))

proc here*(s: Speaker): Value =
  ## that `s` is listening, now
  presence(s.by, now())

proc gone*(s: Speaker): Value =
  ## that `s` has stopped listening, now
  presence(s.by, now())

proc digestOf*(h: Heard): Value =
  ## what a message names what it answers by: the digest of the answer as
  ## it was put
  digest(h.answer, Blake2bAlgo).toValue

proc nameOf*(id: Value): string =
  ## a name to show for an ID: its first name that is a symbol or text
  for n in identities(id):
    if n.isKind({bSym, bText}): return n.text
  $id

proc vouched*(h: Heard): bool =
  ## whether the answer came signed by a key its speaker goes by
  h.signer.isSome and h.said.answer(ByQ).isSome and
    h.said.answer(ByQ).get.knownAs(bytes(@(h.signer.get)))

type Turn = Ranked[(Value, bool)]   # who, and whether they came or went

proc turns(local: BVar[Value, Ranked[Value]]): Stream[Turn] =
  ## who a reader has been told came and went, in the order the jam heard it
  proc told(q: Value, coming: bool): Stream[Turn] =
    local.heardIn(q).filterMaps(block:
      let id = it.said.answer(ByQ)
      if id.isNone: none(Turn)
      else: some(Turn(rank: it.rank, answer: (id.get, coming))))
  byRank(told(HereQ, true), told(GoneQ, false))

proc who*(local: BVar[Value, Ranked[Value]]): seq[Value] =
  ## who a reader has been told is here and not gone since, in the order
  ## they came
  for t in local.turns:
    let (id, coming) = t.answer
    result.keepItIf(not sharesIdentity(it, id))
    if coming: result.add id

proc wasHere*(local: BVar[Value, Ranked[Value]], id: Value, rank: int): bool =
  ## whether a reader has been told that someone going by `id` was here
  ## when the jam heard `rank`: they came before it and hadn't gone
  for t in local.turns:
    if t.rank > rank: break
    if sharesIdentity(t.answer[0], id): result = t.answer[1]

# ================ stamps ================

type
  Stamp* = object
    ## a jam's signed word that it heard an answer to `q` at `rank`: a
    ## message of its tea-time order, (tea-msg R T PREV (Q D))
    q*: Value          ## the question the answer was put to
    rank*: int         ## where the jam heard it: the message's ordinal
    digest*: Value     ## of the answer as put, the digest `re` names
    at*: int64         ## when, by the jam's clock, in milliseconds
    prev*: Value       ## the digest of the message before it, or nil
    record*: Value     ## the message itself
    signer*: Key       ## the key that signed it

proc stampOf*(said: Value, signer: Key): Option[Stamp] =
  ## the stamp a jam told, if `said` is one: a tea-msg whose value is
  ## (Q D), as `signer` signed it
  if not TeaMsg.fits(said): return none(Stamp)
  let m = TeaMsg.fromValue(said)
  if not m.value.isKind(bRec, unmarked) or m.value.items.len != 2: return none(Stamp)
  if not m.ordinal.isInt or m.ordinal.toInt < 0 or not m.at.isInt: return none(Stamp)
  some Stamp(q: m.value.items[0], rank: m.ordinal.toInt, digest: m.value.items[1],
             at: m.at.toInt, prev: m.prev, record: said, signer: signer)

proc stampOf*(h: Heard): Option[Stamp] =
  ## the stamp a jam told, if `h` is one: a key's signature over the
  ## message itself. A signed put (Q A) whose A is a tea-msg is only
  ## that key putting it, and is no stamp
  let o = opened(h.answer)
  if o.isNone or o.get.signer.isNone or not TeaMsg.fits(o.get.said): return none(Stamp)
  stampOf(o.get.said, o.get.signer.get)

proc vouches*(s: Stamp, h: Heard): bool =
  ## whether a stamp is the jam's word for what a reader heard: the same
  ## question, rank and answer
  s.q == h.q and s.rank == h.rank and s.digest == h.digestOf

proc stamps*(local: BVar[Value, Ranked[Value]], stampsQ: Value, key: Key): Stream[Stamp] =
  ## the stamps a reader has been told under `stampsQ` that `key` signed
  local.heardIn(stampsQ).filterMaps(block:
    let s = stampOf(it)
    if s.isSome and s.get.signer == key: s else: none(Stamp))

proc unchained*(local: BVar[Value, Ranked[Value]], stampsQ: Value, key: Key): seq[Stamp] =
  ## the stamps `key` signed that break its chain, in the order of the
  ## ranks they stamp: one that doesn't name the stamp before it, or that
  ## stamps a rank already stamped. A stamp missing, reordered, or signed
  ## twice for one rank shows here; the first a reader has can't be
  ## checked against what it hasn't been told
  var all = local.stamps(stampsQ, key).toSeq
  all.sort((a, b) => cmp(a.rank, b.rank))
  for i in 1 .. all.high:
    if all[i].rank == all[i - 1].rank or
       all[i].prev != digest(all[i - 1].record, Blake2bAlgo).toValue:
      result.add all[i]
