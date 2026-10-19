##[
  claims: evidence composed into one value a reader checks.

  Each reading in evidence, hidden and clave checks one value and says
  one thing: this proof of inclusion holds, this signature is by this
  key, this stamp vouches for this answer. A claim composes them,

    (claim FIND {EVIDENCE …})

  what the claimant says, as a find, of the evidence it carries. What
  a value of evidence entails is a statement, (Q A), and it entails
  one only when its own check holds; a value that reads as no evidence
  entails nothing, so nothing in a claim states anything by itself: a
  bare (Q A) handed in as evidence is a value, not a statement. This
  module's reading of evidence:

    (in ROOT I LEAF [SIB …]) holds      ((in ROOT I) LEAF)
    (grows OLDER NEWER [SIB …]) holds   ((grew OLDER) NEWER)
    (opening ROOT RANGE …) holds        ((opened ROOT RANGE) {M …}), and
                                        ((member ROOT RANGE) M) for each
    (changed BEFORE AFTER) holds        ((scope OLDER NEWER RANGE)
                                          {added: {M …} removed: {M …}}),
                                        ((added OLDER NEWER RANGE) M) and
                                        ((removed OLDER NEWER RANGE) M)
                                        for each, and
                                        ((unchanged-outside OLDER NEWER) RANGE)
                                        when the pair shows that
    (signed V SIG) holds                ((signed KEY) V), and what V
                                        entails; when V is a put (Q A),
                                        ((put KEY Q) A) and what A
                                        entails too
    (receipt (Q R A) STAMP) vouched     ((stamped KEY) (Q R A))
    (equivocation A B) convicts         ((convicted KEY) SLOT)
    (shown (hidden D) [STEP …] NODE)    ((part (hidden D) [PLACE …]) V)
      holds                             when NODE is a leaf, V its value;
                                        ((frame (hidden D) [PLACE …])
                                          (KIND (root N R))) when NODE
                                        is a frame node, as it is; PLACE
                                        a step without its siblings
    BYTES reading as exactly one value  ((reads BYTES) V), and what V
                                        entails
    (claim FIND {E …})                  what each E entails
    any value V, when asked             ((digest-of V) D), one per
                                        algorithm

  The last is answered on demand, never held: a value's digests are
  what it already is, and a settled clause ((digest-of V) D) asks for
  them. BYTES are read at the raw edge by the codec, so a claim can
  carry CE as it was received and a reader hears what it says only if
  it is well-formed; nothing is re-encoded to find out. A signature
  entails what its key said, whatever the key: which keys count is the
  reader's. An opening entails what it shows: that the members shown
  are all the members in the range, and so a scope, an absence, or
  that nothing else moved, holds only if the committed run was a
  canonical set, which no opening proves; a reader that leans on it
  holds that as a premise of its own, such as ((canonical) ROOT), and
  joins on it.

  What evidence entails is a search, `Entails`, asked a value. This
  module's reading is one `Reading`, and `entailments` composes any
  number into one search, each asked for what the values inside a
  signature, a claim or raw bytes entail, so a reader may entail more
  from the same evidence, or less, and nested evidence reaches every
  reading.

  A reader brings premises, what it holds that no evidence can carry:
  which key is whose, which order it believes, what it heard itself.
  `convinced` asks the claim's find of the statements the evidence
  entails and the reader's premises together, and answers, for each
  answer the find gives and each way it came to it, the records it
  rests on, as the subjects held them, the entailed and the given
  apart:

    (convinced ANSWER {ENTAILED …} {GIVEN …})

  A statement both entailed and given convinces twice, once resting on
  each. Nothing fills a premise but the reader: a clause nothing
  answers answers nothing, and that silence is all there is to being
  unconvinced. The checker is a search, `convincing`, asked claims.
]##

import std/[options, sequtils]
import ../[core, mold, queries]
import ./[jam, evidence, hidden]
import ./crypto/[clave, digest]
export mold

refuseWith MoldError

moldable """{
  (struct claim {exact (rep record) (nim ClaimValue)} (asks any) (evidence {any}))
  (struct convinced {exact (rep record) (nim Conviction)}
    (answer any) (entailed {any}) (given {any}))
}"""

type
  Claim* = ref object of ClaimValue
    ## a claim, read: its find read once, with it
    find*: Find

  Entails* = Search[Value, Value]
    ## what evidence entails: asked a value, the statements it carries

  Reading* = (Value, Entails) -> Stream[Value]
    ## one way of reading evidence: what `v` entails, asking `again`
    ## for what the values inside it entail

blet"{grew member stamped convicted reads}"
blet"""{in-head: in opened-head: opened scope-head: scope added-head: added
  removed-head: removed unchanged-outside-head: unchanged-outside
  signed-head: signed put-head: put part-head: part frame-head: frame}"""
blet("{evidence-name: evidence}", false)

method afterLoad(self: Claim) =
  self.find = try: Find.fromValue(self.asks)
              except BasslineError as e: refuse "a claim asks a find: " & e.msg
  guard self.find.subjects.len == 0,
    "a claim's find asks of its evidence and what the reader holds, naming nothing: " & $self.asks
  guard not self.find.counting,
    "a claim's find answers what it finds; a reader counts convictions: " & $self.asks

proc claim*(asks: Value, evidence: openArray[Value]): Claim =
  ## a claim, read: `asks` a find naming no subjects, over `evidence`
  Claim.fromValue(ClaimValue(asks: asks, evidence: @evidence).toValue)

# ================ what evidence entails ================

proc statement*(q, a: Value): Value =
  ## a statement: Q answered by A
  initRec(@[q, a])

proc entails*(v: Value, again: Entails): Stream[Value] =
  ## this module's reading of evidence: the statements `v` entails when
  ## its own check holds, what is inside it asked of `again`; nothing
  ## for a value that reads as no evidence, or whose check fails
  var into: seq[Value]
  template inner(x: Value) = into.add again[x].toSeq
  let p = Inclusion.maybeLoad(v)
  if p.isSome:
    if p.get.holds:
      into.add statement(initRec(@[inHead, p.get.root.toValue, p.get.index.toValue]), p.get.leaf)
    return initStream(into)
  let g = Growth.maybeLoad(v)
  if g.isSome:
    if g.get.holds:
      into.add statement(initRec(@[grew, g.get.older.toValue]), g.get.newer.toValue)
    return initStream(into)
  let o = Opening.maybeLoad(v)
  if o.isSome:
    if o.get.holds:
      let (root, range, ms) = (o.get.root.toValue, o.get.range, o.get.members)
      into.add statement(initRec(@[openedHead, root, range]), initSet(ms))
      for m in ms: into.add statement(initRec(@[member, root, range]), m)
    return initStream(into)
  let ch = Changed.maybeLoad(v)
  if ch.isSome:
    if ch.get.holds:
      let (older, newer, range) =
        (ch.get.before.root.toValue, ch.get.after.root.toValue, ch.get.before.range)
      let (added, removed) = ch.get.scope
      into.add statement(initRec(@[scopeHead, older, newer, range]),
                         bl"{added: {@added} removed: {@removed}}")
      for m in added: into.add statement(initRec(@[addedHead, older, newer, range]), m)
      for m in removed: into.add statement(initRec(@[removedHead, older, newer, range]), m)
      if ch.get.unchangedOutside:
        into.add statement(initRec(@[unchangedOutsideHead, older, newer]), range)
    return initStream(into)
  let r = Receipt.maybeLoad(v)
  if r.isSome:
    let k = r.get.vouchedBy
    if k.isSome: into.add statement(initRec(@[stamped, k.get.toValue]), r.get.told)
    return initStream(into)
  let e = Equivocation.maybeLoad(v)
  if e.isSome:
    let k = e.get.convicts
    if k.isSome:
      # convicts read both words and found their slots one
      let s = slot(opened(e.get.a).get.said, k.get)
      into.add statement(initRec(@[convicted, k.get.toValue]), s.get)
    return initStream(into)
  let sh = Shown.maybeLoad(v)
  if sh.isSome:
    if sh.get.holds:
      let (hidden, places) = (sh.get.hidden.toValue, sh.get.places)
      let leaf = leafOf(sh.get.node)
      if leaf.isSome:
        into.add statement(initRec(@[partHead, hidden, places]), leaf.get)
      else:
        into.add statement(initRec(@[frameHead, hidden, places]), sh.get.node)
    return initStream(into)
  let c = Claim.maybeLoad(v)
  if c.isSome:
    for x in c.get.evidence: inner(x)
    return initStream(into)
  let s = Signed.maybeLoad(v)
  if s.isSome:
    if s.get.holds:
      let (key, said) = (s.get.sig.pubkey.toValue, s.get.value)
      into.add statement(initRec(@[signedHead, key]), said)
      inner(said)
      matchValue said:
      of "($q $a)":
        into.add statement(initRec(@[putHead, key, q]), a)
        inner(a)
      else: discard
    return initStream(into)
  if v.isKind(bBytes, unmarked):
    let read = try: some Value.decode(v.bytes) except ValueError: none(Value)
    if read.isSome:
      into.add statement(initRec(@[reads, v]), read.get)
      inner(read.get)
  initStream(into)

proc entailments*(readings: openArray[Reading]): Entails =
  ## what evidence entails under these readings together: asked a
  ## value, each reading's statements take turns, and what is inside
  ## the value is asked of the whole again
  let rs = @readings
  var whole: Entails
  whole = newSearch[Value, Value](v => alt(initStream(rs).maps(it(v, whole)).toSeq))
  whole

proc entailments*(): Entails =
  ## what evidence entails under this module's reading alone
  entailments([Reading(entails)])

proc statements*(c: Claim, entails = entailments()): Stream[Value] =
  ## every statement the claim's evidence entails
  initSet(c.evidence).members.flatMaps(entails[it])

proc digestsOf(q: Value): Stream[Value] =
  ## (digest-of V) answered on demand, one digest per algorithm
  matchValue q:
  of "(digest-of $v)":
    initStream(@[digest(v, Blake2bAlgo).toValue, digest(v, Sha256Algo).toValue])
  else: empty Value

proc evidenceOf*(c: Claim): Value =
  ## the name the claim's evidence answers by: evidence, and the
  ## claim's digest
  identity(evidenceName, digest(c.toValue, Blake2bAlgo).toValue)

proc subject*(c: Claim, entails = entailments()): Subject =
  ## the claim's evidence as a subject a find asks: the statements it
  ## entails, held, and digests on demand
  let part = c.evidenceOf
  joined(altKind, @[held(part, @[initSet(c.statements(entails).toSeq)], false, false),
                    answering(digestsOf, part)])

# ================ premises ================

proc premises*(v: Value): Subject =
  ## what a reader brings, as a subject: a search space written down
  ## with what it holds, or an object answering its own records
  if v.hasKind(searchSpace):
    let ranked = v.hasKind(rankedKind)
    return held(v, spaceBodies(v, ranked), ranked, false)
  guard v.isObject, "premises are an object, or a space written down: " & $v
  thing(v)

proc given*(records: varargs[Value]): Value =
  ## an object of a reader's premises, (Q A) each, going by `premises`
  describe([], identity(sym"premises"), records)

# ================ being convinced ================

proc convinced*(c: Claim, brought: Subject, entails = entailments(),
                asked = none(Value)): Stream[Conviction] =
  ## what the claim convinces a reader of: each answer its find gives,
  ## asked of the evidence's statements and the premises `brought`
  ## together, once for each set of records that answers it, with the
  ## records it rests on as held, the entailed and the given apart.
  ## Nothing where evidence and premises never meet
  var fd = c.find
  fd.sayingWhy = true
  let part = c.evidenceOf
  rows(fd, asked, @[c.subject(entails), brought]).maps(block:
    var entailed, given: seq[Value]
    for w in it.why:
      if w.part == part: entailed.add w.record else: given.add w.record
    Conviction(answer: it.answer.items[1], entailed: entailed.deduplicate, given: given.deduplicate))

proc convinced*(c: Claim, brought: Value, entails = entailments(),
                asked = none(Value)): Stream[Conviction] =
  convinced(c, premises(brought), entails, asked)

proc convincing*(brought: Subject, entails = entailments()): Search[Value, Value] =
  ## the checker as a search: asked a claim, it answers each conviction
  ## written down; asked anything else, nothing
  newSearch[Value, Value](q => (block:
    let c = Claim.maybeLoad(q)
    if c.isNone: return empty(Value)
    convinced(c.get, brought, entails).maps(it.toValue)))

proc convincing*(brought: Value, entails = entailments()): Search[Value, Value] =
  convincing(premises(brought), entails)
