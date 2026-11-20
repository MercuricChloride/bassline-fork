## teatime: one order over values, kept by one key.
##
## A reflector takes values one at a time and signs each with the next
## ordinal, its own clock, and the digest of the message before it:
##
##   (signed (tea-msg N AT PREV V) SIGNATURE)
##
## N counts from 0, AT is milliseconds by the reflector's clock, and
## PREV is the digest of the tea-msg record before, nil for the first.
## The key that signs is the order's identity. The reflector keeps
## nothing of what it signs: a value given twice is two messages.
##
## A history is what a reader holds of one order: each message once, by
## ordinal, checked as the key's. The ordinals it lacks are its gaps,
## each a (tea-sync KEY LO HI) that anyone holding them can answer, with
## no HI for everything onward; a reader fills a gap by adding what it is
## told. Two words by the key for one ordinal, or a message whose PREV
## names another word than the one held, are kept apart as conflicts:
## the key spoke twice, and a reader holding both words has learned that
## of the key. The history keeps the word it held first.
##
## Whoever acts on an order acts on what a history holds, in ordinal
## order, their own messages among them once reflected.

import std/[options, times]
import ../core
import ./crypto/[clave, digest]

type TeaTimeError* = object of BasslineError

refuseWith TeaTimeError

moldable """{
  (struct tea-msg {exact (rep record)}
    (ordinal number) (at number) (prev any) (value any))
  (struct tea-sync {exact (rep record)}
    (source (bytes {(len 32)})) (lo number) (hi {optional} number))
}"""

proc now*(): int64 =
  ## milliseconds since the epoch, by this machine's clock
  (epochTime() * 1000).int64

# ================ the reflector ================

type
  Reflector* = ref object
    kp: Keypair
    count: BNum    ## the next ordinal
    prev: Value    ## the digest of the last message, nil before the first

proc initReflector*(kp: Keypair): Reflector =
  ## a reflector beginning an order
  Reflector(kp: kp, count: 0, prev: null())

proc key*(self: Reflector): Key =
  ## the order's identity
  self.kp.pubkey

proc keypair*(self: Reflector): Keypair =
  ## the pair it signs with
  self.kp

proc next*(self: Reflector): BNum =
  ## the ordinal its next message takes
  self.count

proc sign*(self: Reflector, val: Value, at = now()): Signed =
  ## the next message of the order: `val` at the next ordinal, at `at` by
  ## the reflector's clock, following the message before
  let value = TeaMsg(ordinal: self.count, at: at, prev: self.prev, value: val).toValue
  result = self.kp.signed(value)
  self.prev = digest(value, Blake2bAlgo).toValue
  inc self.count

# ================ a history ================

type
  Reflected* = object
    ## a message of an order as a history holds it
    signed*: Signed   ## as the reflector said it
    msg*: TeaMsg      ## read
    digest*: Value    ## of the tea-msg record: what the next message's prev names

  Added* = enum
    added        ## new to the history
    known        ## held already, the same word
    conflicting  ## another word by the key for a slot it had spoken for

  History* = object
    reflector*: Key
    values: BTree[BNum, Reflected]
    conflicts*: seq[tuple[held, other: Reflected]]  ## two words for one slot

proc initHistory*(reflector: Key): History =
  History(reflector: reflector, values: newBTree[BNum, Reflected]())

proc toValue*(r: Reflected): Value = r.signed.toValue

proc ordinal*(r: Reflected): BNum = r.msg.ordinal

proc follows*(b, a: Reflected): bool =
  ## whether `b` is the message after `a` by its own word: its prev
  ## names `a`
  b.msg.prev == a.digest

proc reflected*(self: History, signed: Signed): Reflected =
  ## reads a signed value as a message of this order, refusing another
  ## key's, one whose signature doesn't hold, and one that isn't a
  ## tea-msg from 0 up, its prev nil at 0 and a digest after
  guard signed.sig.pubkey == self.reflector, "signed by another key"
  guard signed.holds, "signature doesn't hold"
  let msg = TeaMsg.fromValue(signed.value)
  guard msg.ordinal >= 0, "ordinal below 0"
  if msg.ordinal == 0:
    guard msg.prev.isKind(bNil), "the first message follows nothing"
  else:
    guard Digest.fits(msg.prev), "prev isn't a digest"
  Reflected(signed: signed, msg: msg, digest: digest(signed.value, Blake2bAlgo).toValue)

proc add*(self: var History, signed: Signed): Added =
  ## takes a message of the order, answering whether it was new, held
  ## already, or another word for a slot the key had spoken for: the
  ## same ordinal, or the ordinal its prev names, or the one whose
  ## held successor names another. A conflicting message is kept apart
  ## with the word it conflicts with, and the history keeps what it held
  let r = self.reflected(signed)
  let n = r.msg.ordinal
  if n in self.values:
    if self.values[n].digest == r.digest: return known
    self.conflicts.add (held: self.values[n], other: r)
    return conflicting
  if n > 0 and (n - 1) in self.values and not r.follows(self.values[n - 1]):
    self.conflicts.add (held: self.values[n - 1], other: r)
    return conflicting
  if (n + 1) in self.values and not self.values[n + 1].follows(r):
    self.conflicts.add (held: self.values[n + 1], other: r)
    return conflicting
  self.values[n] = r
  added

proc len*(self: History): int = self.values.len

proc sync*(self: History, lo: BNum, hi = none(BNum)): TeaSync =
  ## the ask for this order's messages from `lo` through `hi`, or onward
  TeaSync(source: self.reflector, lo: lo, hi: hi)

proc gaps*(self: History, lo, hi: BNum): seq[TeaSync] =
  ## the runs of ordinals from `lo` through `hi` the history lacks, each
  ## as the sync that asks for it
  var next = lo
  for e in self.values.pairsFrom(lo, hi):
    if e.key > next: result.add self.sync(next, some(e.key - 1))
    next = e.key + 1
  if next <= hi: result.add self.sync(next, some hi)

proc gaps*(self: History): seq[TeaSync] =
  ## the gaps below the highest ordinal held
  if self.values.len > 0: self.gaps(0, self.values.high) else: @[]

proc onward*(self: History): TeaSync =
  ## the ask for everything after the highest ordinal held
  self.sync(if self.values.len > 0: self.values.high + 1 else: 0'num)

proc hasAll*(self: History, lo, hi: BNum): bool = self.gaps(lo, hi).len == 0

proc hasAll*(self: History): bool = self.gaps.len == 0

iterator replay*(self: History, lo, hi: BNum): Reflected =
  ## the messages held from `lo` through `hi`, in ordinal order
  for e in self.values.pairsFrom(lo, hi): yield e.val

iterator replay*(self: History): Reflected =
  ## every message held, in ordinal order
  for e in self.values.pairs: yield e.val

iterator replay*(self: History, s: TeaSync): Reflected =
  ## what the history holds of what a sync asks, refusing one for
  ## another order
  guard s.source == self.reflector, "a sync for another order"
  if s.hi.isSome:
    for r in self.replay(s.lo, s.hi.get): yield r
  else:
    for e in self.values.pairsFrom(s.lo): yield e.val

proc initReflector*(kp: Keypair, h: History): Reflector =
  ## a reflector going on with the order `h` holds, from after its
  ## highest message
  guard kp.pubkey == h.reflector, "the history is another key's"
  if h.values.len == 0: return initReflector(kp)
  let last = h.values[h.values.high]
  Reflector(kp: kp, count: last.msg.ordinal + 1, prev: last.digest)

when isMainModule:
  var seed: array[32, byte]
  let kp = keypairFromSeed(seed)
  let reflector = initReflector(kp)
  var history = initHistory(reflector.key)
  var msgs: seq[Signed]

  for each in rv"[a b c d e f g]".items:
    msgs.add reflector.sign(each)
    echo history.add(msgs[^1]), " / ", history.add(msgs[^1])
  echo "gaps: ", history.gaps, "  hasAll: ", history.hasAll, "  onward: ", history.onward.toValue

  var partial = initHistory(reflector.key)
  for i in [0, 1, 4, 6]: discard partial.add msgs[i]
  echo "partial gaps:"
  for g in partial.gaps: echo "  ", g.toValue, "  round-trips: ", TeaSync.fromValue(g.toValue).toValue == g.toValue
  echo "filling from the full history:"
  for g in partial.gaps:
    for r in history.replay(g): echo "  ", r.ordinal, " ", partial.add(r.signed)
  echo "partial hasAll: ", partial.hasAll

  let resumed = initReflector(kp, history)
  echo "resumed: ", history.add(resumed.sign(rv"h")), " onward now ", history.onward.toValue

  let fork = initReflector(kp)
  echo "fork at 0: ", history.add(fork.sign(rv"x")), "  conflicts: ", history.conflicts.len
  echo "fork at 1: ", history.add(fork.sign(rv"y")), "  conflicts: ", history.conflicts.len
  for r in history.replay(0, 0): echo "held 0 still: ", r.msg.value
