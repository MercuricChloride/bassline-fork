##[
  evidence: what an order entails, as values anyone can check.

  A jam orders what it hears, and given a key stamps each rank. The
  readings below are over such an order, or over any run of values. A
  program adopts them one at a time, and each is a value carrying all
  its checker needs: nothing about who keeps the log, where it is, or
  how it was heard.

    (root N D)                       N leaves hash to D
    (in (root N D) I LEAF [SIB …])   leaf I of N is LEAF, SIBs leaf-up
    (grows (root M D) (root N E) [SIB …])   E's leaves extend D's
    (checkpoint OVER Q R (root N D)) signed: the answers its signer
                                     heard to Q from the order OVER,
                                     through rank R, hash to D
    (equivocation A B)               one key's two words for one slot
    (receipt (Q R A) STAMP)          an answer as told, and the stamp
                                     a jam signed for it
    (opening (root N D) RANGE I [LEAF …] [SIB …])
                                     the members of a set in RANGE,
                                     with the neighbours that bracket
                                     them, from leaf I
    (changed OPENING OPENING)        one range against two roots

  The tree is made of values. A leaf's node is the digest of (leaf V),
  an inner node the digest of (node L R), both blake2b over CE, and the
  root of no leaves the digest of (node): the heads keep a leaf from
  passing as a node. A tree of n leaves splits at the greatest power of
  two below n, so its shape is fixed by n alone, a proof of inclusion
  or growth is logarithmic in n, and a proof naming the wrong place has
  the wrong length.

  Leaves may be anything, marked or not: a set's members in their own
  order commit to the set, and an inclusion proof then shows membership
  to someone who doesn't hold it. A checkpoint's leaves are the digests
  of the answers as put, in rank order, the digest `re` names, so a
  proof of inclusion in a checkpoint is about the value others already
  name a message by. OVER is the order the ranks belong to: the jam's
  identity, as it answers (jam). A reader hearing two jams checkpoints
  each, and the two are two words about two orders.

  A set's members in their own CE order are a tree too, and an
  opening reveals exactly the members in a range: a span of leaves
  that holds every member in the range and, where the set goes on
  past the range, one neighbour on each side, which is below or above
  it; the siblings are the subtree digests hanging off the span, so a
  span's proof is about 2 log n digests however wide the span. A
  range is (from LO HI), closed at both ends by CE order, or
  (under P), every value P prefixes, which CE keeps contiguous since a
  record spells its head first, so one range opens everything under a
  head. The checker rebuilds the root from the span, tests the span's
  strict CE order and its brackets, and takes the members within the
  range: given that the committed sequence is a canonical set, every
  member in the range is among them. That premise is the committer's:
  a sequence sorted wrong can hide a member outside the span it
  reveals, and an audit of the whole, or two overlapping openings that
  disagree, catches it; no one opening proves it. An opening whose
  range holds nothing is a proof of absence for everything in the
  range. Two openings of one range against two roots show that
  range's whole change, what was added and what removed, and nothing
  about elsewhere, except that when both roots count the same and the
  spans and siblings coincide, nothing outside the range moved either.

  A slot is what a key speaks for once, (slot OVER Q R): for a
  checkpoint, its rank under its checkpoints question over its order;
  for a stamp, its ordinal under the order its key keeps, (slot KEY nil
  R), since the key that signs a tea-time order is that order. Two
  signed words by one key for one slot that differ are an equivocation,
  which convicts the key with no other knowledge: a second word is the
  offence, whatever it says. Two keys are two keys; whether they are two
  operators, and which key is whose, is each reader's own knowledge.
]##

import std/[bitops, options, sequtils]
import ../[core, mold, queries]
import ./jam
import ./crypto/[clave, digest]
export mold

refuseWith MoldError

moldable """{
  (struct root {exact (rep record)} (count number) (digest value))
  (struct in {exact (rep record) (nim Inclusion)}
    (root root) (index number) (leaf any) (path [value]))
  (struct grows {exact (rep record) (nim Growth)}
    (older root) (newer root) (path [value]))
  (struct checkpoint {exact (rep record)} (over any) (q any) (rank number) (root root))
  (struct equivocation {exact (rep record)} (a value) (b value))
  (struct receipt {exact (rep record)} (told value) (stamp value))
  (struct from {exact (rep record) (nim FromTo)} (lo any) (hi any))
  (struct under {exact (rep record)} (prefix any))
  (struct opening {exact (rep record)}
    (root root) (range value) (index number) (span [any]) (path [value]))
  (struct changed {exact (rep record)} (before opening) (after opening))
}"""

blet"{checkpoints}"  # (checkpoints Q): where checkpoints of Q go
blet"{slot-head: slot}"
blet("{node}", false)
blet("{leaf-head: leaf}", false)

proc count(n: BNum, what: string): int =
  guard n.isInt and n.toInt >= 0, what & " is a count"
  n.toInt

method afterLoad(self: Inclusion) =
  guard count(self.index, "index") < count(self.root.count, "count"),
    "index is a place among the leaves"
method afterLoad(self: Checkpoint) = discard count(self.rank, "rank")
method afterLoad(self: FromTo) =
  guard cmp(self.lo, self.hi) <= 0, "a range runs from its low end to its high end"
method afterLoad(self: Opening) =
  guard count(self.index, "index") + self.span.len <= count(self.root.count, "count"),
    "the span is a run of the leaves"
  guard FromTo.maybeLoad(self.range).isSome or Under.maybeLoad(self.range).isSome,
    "a range is (from LO HI) or (under P)"

# ================ the tree ================

proc nodeDigest*(preimage: Value): Value =
  ## the digest a node of the tree is: blake2b over its preimage's CE
  digest(preimage, Blake2bAlgo).toValue

proc leaf*(v: Value): Value =
  ## a leaf's preimage, (leaf V)
  initRec(@[leafHead, v])

proc leafNode*(v: Value): Value =
  ## a leaf's node, the digest of (leaf V)
  nodeDigest(leaf(v))

proc innerNode(l, r: Value): Value =
  nodeDigest(initRec(@[node, l, r]))

proc splitAt(n: int): int =
  ## the greatest power of two below n, for n of two or more
  1 shl fastLog2(n - 1)

proc treeRoot*(nodes: openArray[Value]): Value =
  ## the root over leaf nodes already digested: a tree whose leaves
  ## are digests of other things, such as a frame's parts each hidden
  ## by its own node
  case nodes.len
  of 0: nodeDigest(initRec(@[node]))
  of 1: nodes[0]
  else:
    let k = splitAt(nodes.len)
    innerNode(treeRoot(nodes.toOpenArray(0, k - 1)),
              treeRoot(nodes.toOpenArray(k, nodes.high)))

proc rootDigest*(leaves: openArray[Value]): Value =
  ## the digest the leaves hash to: the tree over their leaf nodes
  treeRoot(leaves.map(leafNode))

proc treePath*(nodes: openArray[Value], i: int): seq[Value] =
  ## the siblings, leaf-up, of node `i` in the tree over `nodes`
  if nodes.len == 1: return
  let k = splitAt(nodes.len)
  if i < k:
    result = treePath(nodes.toOpenArray(0, k - 1), i)
    result.add treeRoot(nodes.toOpenArray(k, nodes.high))
  else:
    result = treePath(nodes.toOpenArray(k, nodes.high), i - k)
    result.add treeRoot(nodes.toOpenArray(0, k - 1))

method afterLoad(self: Root) =
  if count(self.count, "count") == 0:
    guard self.digest == rootDigest([]), "a root of no leaves is the digest of (node)"

proc root*(leaves: openArray[Value]): Root =
  ## (root N D): the leaves, by count and digest
  Root(count: leaves.len, digest: rootDigest(leaves))

proc inclusion*(leaves: openArray[Value], i: int): Inclusion =
  ## the proof that leaf `i` is in the root of `leaves`
  Inclusion(root: root(leaves), index: i, leaf: leaves[i],
            path: treePath(leaves.map(leafNode), i))

proc rebuiltFrom*(node: Value, i, n: int, path: openArray[Value]): Option[Value] =
  ## the root `path` rebuilds from leaf node `i` of `n`, if its length
  ## is the one the tree's shape fixes
  if n == 1:
    return if path.len == 0: some node else: none(Value)
  if path.len == 0: return none(Value)
  let k = splitAt(n)
  template below: untyped = path.toOpenArray(0, path.high - 1)
  if i < k:
    let l = rebuiltFrom(node, i, k, below)
    if l.isSome: some innerNode(l.get, path[^1]) else: l
  else:
    let r = rebuiltFrom(node, i - k, n - k, below)
    if r.isSome: some innerNode(path[^1], r.get) else: r

proc rebuilt*(leaf: Value, i, n: int, path: openArray[Value]): Option[Value] =
  ## the root `path` rebuilds from leaf `i` of `n`
  rebuiltFrom(leafNode(leaf), i, n, path)

proc holds*(p: Inclusion): bool =
  ## whether the proof holds: its path rebuilds its root from its leaf
  let n = p.root.count.toInt
  p.index.toInt < n and
    rebuilt(p.leaf, p.index.toInt, n, p.path) == some p.root.digest

proc growth*(leaves: openArray[Value], m: int): Growth =
  ## the proof that the root of the first `m` leaves grows into the root
  ## of all of them
  var path: seq[Value]
  proc walk(leaves: openArray[Value], m: int, known: bool) =
    ## `known`: whether the older root is one the checker holds already,
    ## so the path needn't carry it
    if m == leaves.len:
      if not known: path.add rootDigest(leaves)
      return
    let k = splitAt(leaves.len)
    if m <= k:
      walk(leaves.toOpenArray(0, k - 1), m, known)
      path.add rootDigest(leaves.toOpenArray(k, leaves.high))
    else:
      walk(leaves.toOpenArray(k, leaves.high), m - k, false)
      path.add rootDigest(leaves.toOpenArray(0, k - 1))
  if 0 < m and m < leaves.len: walk(leaves, m, true)
  Growth(older: root(leaves.toOpenArray(0, m - 1)), newer: root(leaves), path: path)

proc regrown(older: Value, m, n: int, known: bool,
             path: openArray[Value]): Option[(Value, Value)] =
  ## the older and newer roots `path` rebuilds, `known` whether the
  ## older tree stands whole here with its root `older` already held
  type Pair = (Value, Value)
  if m == n:
    if known:
      return if path.len == 0: some (older, older) else: none(Pair)
    return if path.len == 1: some (path[0], path[0]) else: none(Pair)
  if path.len == 0: return none(Pair)
  let k = splitAt(n)
  template below: untyped = path.toOpenArray(0, path.high - 1)
  if m <= k:
    let r = regrown(older, m, k, known, below)
    if r.isNone: return r
    some (r.get[0], innerNode(r.get[1], path[^1]))
  else:
    let r = regrown(older, m - k, n - k, false, below)
    if r.isNone: return r
    some (innerNode(path[^1], r.get[0]), innerNode(path[^1], r.get[1]))

proc holds*(g: Growth): bool =
  ## whether the proof holds: its path rebuilds both roots, the older
  ## standing whole inside the newer
  let (m, n) = (g.older.count.toInt, g.newer.count.toInt)
  if n < m: return false
  if m == 0:
    return g.path.len == 0 and g.older.digest == rootDigest([]) and
      (n > 0 or g.newer.digest == rootDigest([]))
  if m == n: return g.path.len == 0 and g.older.digest == g.newer.digest
  regrown(g.older.digest, m, n, true, g.path) == some (g.older.digest, g.newer.digest)

# ================ checkpoints ================

proc checkpointsQ*(q: Value): Value =
  ## where checkpoints of `q` are put
  initRec(@[checkpoints, q])

proc leaves*(local: BVar[Value, Ranked[Value]], q: Value, through: int): seq[Value] =
  ## the digests of the answers a reader heard to `q` through rank
  ## `through`, as put, in rank order
  local.heardIn(q).filters(it.rank <= through).maps(it.digestOf).toSeq

proc jamOf*(local: BVar[Value, Ranked[Value]]): Option[Value] =
  ## the identity of the jam a reader was told by: what it answered
  ## (jam). A reader's space holds what one jam told it, as its ranks
  ## are that jam's; a space answering (jam) twice was told by two, and
  ## names neither
  let told = local[jamQ].toSeq
  if told.len != 1: return none(Value)
  let o = opened(told[0].answer)
  if o.isNone: return none(Value)
  some identityOf(o.get.said)

proc checkpoint*(local: BVar[Value, Ranked[Value]], q: Value, through: int): Checkpoint =
  ## a reader's word on what it heard to `q` from the jam that told it,
  ## through rank `through`; refused when the space was told by no jam,
  ## or by more than one, since the ranks would be of two orders
  let over = jamOf(local)
  guard over.isSome, "a checkpoint is over one order: this space answers (jam) once or not at all"
  Checkpoint(over: over.get, q: q, rank: through, root: root(local.leaves(q, through)))

proc checkpointOf*(h: Heard): Option[Checkpoint] =
  ## the checkpoint someone put, if `h` is one: signed, and put where
  ## checkpoints of its question go
  if h.signer.isNone: return none(Checkpoint)
  let c = Checkpoint.maybeLoad(h.said)
  if c.isNone or h.q != checkpointsQ(c.get.q): return none(Checkpoint)
  c

# ================ equivocation ================

proc slot*(said: Value, signer: Key): Option[Value] =
  ## what a signed value speaks for once, (slot OVER Q R): a stamp's
  ## ordinal under its key's order, (slot KEY nil R), or, for a put
  ## (Q A), a checkpoint's rank under its checkpoints question over its
  ## order
  let s = stampOf(said, signer)
  if s.isSome:
    return some initRec(@[slotHead, signer.toValue, null(), toValue(s.get.rank)])
  matchValue said:
  of "($q $a)":
    let c = Checkpoint.maybeLoad(a)
    if c.isSome and q == checkpointsQ(c.get.q):
      return some initRec(@[slotHead, c.get.over, q, c.get.rank.toValue])
  else: discard
  none(Value)

proc equivocation*(a, b: Value): Equivocation =
  ## two signed puts as evidence against their key
  Equivocation(a: a, b: b)

proc convicts*(e: Equivocation): Option[Key] =
  ## the key both words are signed by, if the evidence holds: the
  ## signatures do, the slots are one, and the words differ
  let (oa, ob) = (opened(e.a), opened(e.b))
  if oa.isNone or ob.isNone or oa.get.signer.isNone or
     oa.get.signer != ob.get.signer: return none(Key)
  let key = oa.get.signer.get
  let (sa, sb) = (slot(oa.get.said, key), slot(ob.get.said, key))
  if sa.isNone or sa != sb or oa.get.said == ob.get.said: return none(Key)
  some key

# ================ receipts ================

proc receipt*(told, stamped: Heard): Receipt =
  ## an answer as a jam told it, with the stamp the jam told for it
  Receipt(told: initRec(@[told.q, toValue(told.rank), told.answer]),
          stamp: stamped.answer)

proc vouchedBy*(r: Receipt): Option[Key] =
  ## the key whose stamp vouches for the answer the receipt carries, if
  ## the stamp holds and is for that answer
  let h = heard(r.told)
  if h.isNone: return none(Key)
  let o = opened(r.stamp)
  if o.isNone or o.get.signer.isNone: return none(Key)
  let s = stampOf(o.get.said, o.get.signer.get)
  if s.isNone or not s.get.vouches(h.get): return none(Key)
  o.get.signer

# ================ openings ================

type Place* = enum
  below, within, above   ## where a value stands against a range

proc place*(range, x: Value): Place =
  ## where `x` stands against a range, (from LO HI) or (under P)
  let f = FromTo.maybeLoad(range)
  if f.isSome:
    return if cmp(x, f.get.lo) < 0: below elif cmp(x, f.get.hi) > 0: above else: within
  let u = Under.maybeLoad(range)
  guard u.isSome, "a range is (from LO HI) or (under P): " & $range
  if prefixes(u.get.prefix, x): within
  elif cmp(x, u.get.prefix) < 0: below
  else: above

proc fromTo*(lo, hi: Value): Value =
  ## the range from `lo` to `hi`, both included
  FromTo(lo: lo, hi: hi).toValue

proc under*(prefix: Value): Value =
  ## the range of everything `prefix` prefixes
  Under(prefix: prefix).toValue

proc spanPath(leaves: openArray[Value], lo, hi: int, into: var seq[Value]) =
  ## the subtree digests hanging off leaves lo..hi, in post-order
  if leaves.len == 1: return
  let k = splitAt(leaves.len)
  if hi < k:
    spanPath(leaves.toOpenArray(0, k - 1), lo, hi, into)
    into.add rootDigest(leaves.toOpenArray(k, leaves.high))
  elif lo >= k:
    spanPath(leaves.toOpenArray(k, leaves.high), lo - k, hi - k, into)
    into.add rootDigest(leaves.toOpenArray(0, k - 1))
  else:
    spanPath(leaves.toOpenArray(0, k - 1), lo, k - 1, into)
    spanPath(leaves.toOpenArray(k, leaves.high), 0, hi - k, into)

proc opening*(members: openArray[Value], range: Value): Opening =
  ## the members in `range`, from `members` in CE order, with the
  ## neighbours that bracket them
  var first = 0
  while first < members.len and place(range, members[first]) == below: inc first
  var last = members.high
  while last >= 0 and place(range, members[last]) == above: dec last
  result = Opening(root: root(members), range: range, index: 0)
  if members.len == 0: return
  let (lo, hi) = (max(first - 1, 0), min(last + 1, members.high))
  result.index = lo
  result.span = members[lo .. hi]
  spanPath(members, lo, hi, result.path)

proc rebuiltSpan(span: openArray[Value], lo, hi, n: int, path: openArray[Value],
                 pos: var int): Option[Value] =
  ## the root `path` rebuilds from `span` standing at leaves lo..hi of n,
  ## `pos` where the next sibling is taken from
  if n == 1:
    return if span.len == 1: some leafNode(span[0]) else: none(Value)
  let k = splitAt(n)
  if hi < k:
    let l = rebuiltSpan(span, lo, hi, k, path, pos)
    if l.isNone or pos >= path.len: return none(Value)
    inc pos
    some innerNode(l.get, path[pos - 1])
  elif lo >= k:
    let r = rebuiltSpan(span, lo - k, hi - k, n - k, path, pos)
    if r.isNone or pos >= path.len: return none(Value)
    inc pos
    some innerNode(path[pos - 1], r.get)
  else:
    let cut = k - lo
    let l = rebuiltSpan(span.toOpenArray(0, cut - 1), lo, k - 1, k, path, pos)
    if l.isNone: return l
    let r = rebuiltSpan(span.toOpenArray(cut, span.high), 0, hi - k, n - k, path, pos)
    if r.isNone: return r
    some innerNode(l.get, r.get)

proc holds*(o: Opening): bool =
  ## whether the opening holds: its span rebuilds its root, is strictly
  ## increasing by CE, and is bracketed, by a leaf below the range on
  ## the left unless it begins the set, and by one above it on the
  ## right unless it ends the set
  let (n, i, w) = (o.root.count.toInt, o.index.toInt, o.span.len)
  if n == 0: return w == 0 and o.path.len == 0 and o.root.digest == rootDigest([])
  if w == 0 or i + w > n: return false
  var pos = 0
  let rebuilt = rebuiltSpan(o.span, i, i + w - 1, n, o.path, pos)
  if rebuilt != some(o.root.digest) or pos != o.path.len: return false
  for k in 1 ..< w:
    if cmp(o.span[k - 1], o.span[k]) >= 0: return false
  (i == 0 or place(o.range, o.span[0]) == below) and
    (i + w == n or place(o.range, o.span[^1]) == above)

proc members*(o: Opening): seq[Value] =
  ## the members the opening shows in its range
  o.span.filterIt(place(o.range, it) == within)

proc absent*(o: Opening, x: Value): bool =
  ## whether the opening shows `x` is no member: it holds, `x` is in
  ## its range, and `x` is not among the members shown
  o.holds and place(o.range, x) == within and x notin o.members

proc changed*(before, after: Opening): Changed =
  ## one range opened against two roots
  Changed(before: before, after: after)

proc holds*(c: Changed): bool =
  ## whether both openings hold and open one range
  c.before.range == c.after.range and c.before.holds and c.after.holds

proc scope*(c: Changed): tuple[added, removed: seq[Value]] =
  ## what the range gained and lost between the roots
  let (b, a) = (c.before.members, c.after.members)
  (a.filterIt(it notin b), b.filterIt(it notin a))

proc unchangedOutside*(c: Changed): bool =
  ## whether the pair shows nothing outside the range moved: both roots
  ## count the same, the spans stand at one place, their siblings
  ## coincide, and the brackets are the same leaves
  if not c.holds or c.before.root.count.toInt != c.after.root.count.toInt or
     c.before.index.toInt != c.after.index.toInt or c.before.span.len != c.after.span.len or
     c.before.path != c.after.path: return false
  for k in 0 ..< c.before.span.len:
    let (x, y) = (c.before.span[k], c.after.span[k])
    if place(c.before.range, x) != within or place(c.after.range, y) != within:
      if x != y: return false
  true
