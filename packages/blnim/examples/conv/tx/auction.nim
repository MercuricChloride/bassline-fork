## An auction. Bids must beat the standing bid, the seller's (close) is
## followed at once by (sold BID), and nothing is taken after it. Ann
## and bob bid on their own whenever they hear someone else's bid.

import std/sugar
import ./common

type Lot = ref object
  standing: Value  ## (bid NAME N), or nil
  closed: bool

proc isBid(v: Value): bool =
  v.isKind(bRec, unmarked) and v.len == 3 and v.head == bl"bid" and v[2].isKind(bNum)

proc open(lot: Lot): Rule =
  (c: Conversation, msg: Msg) => not lot.closed or c.refusing(msg, bl"closed")

proc beats(lot: Lot): Rule =
  result = proc(c: Conversation, msg: Msg): bool =
    let v = msg.value
    if not v.isBid: return false
    if v[1] != msg.by: return c.refusing(msg, bl"not-yours")
    if lot.standing.kind != bNil and v[2].num.toInt <= lot.standing[2].num.toInt:
      return c.refusing(msg, bl"too-low")
    c.keep: lot.standing = v
    true

proc closing(lot: Lot, seller: Value): Rule =
  result = proc(c: Conversation, msg: Msg): bool =
    if msg.value != bl"(close)": return false
    if msg.by != seller: return c.refusing(msg, bl"not-the-seller")
    let sold = lot.standing
    c.keep: lot.closed = true
    c.reflect(msg, toSpeaker = true)
    c.say bl"(sold $sold)"
    true

proc bidder(name: string, upTo: int): Person =
  result = person(name)
  result.hears = proc(p: Person, msg: Msg) =
    let v = msg.value
    if v.isBid and v[1] != p.name and v[2].num.toInt < upTo:
      let (me, n) = (p.name, v[2].num.toInt + 1)
      p.says(msg.room, bl"(bid $me $n)")

let
  lot = Lot()
  room = room(all(open(lot), first(all(beats(lot), asSaid()), closing(lot, bl"sam"))))
  (ann, bob, carol, sam, dan, fay) =
    (bidder("ann", 13), bidder("bob", 12), person"carol", person"sam", person"dan", person"fay")
fay.hears = proc(p: Person, msg: Msg) =
  if msg.value == bl"(close)": p.says(msg.room, bl"gg")
for p in [ann, bob, carol, sam, dan, fay]: p.join room

carol.says(room, bl"(bid carol 10)")
ann.says(room, bl"(close)")
sam.says(room, bl"(close)")
dan.says(room, bl"(bid dan 50)")
