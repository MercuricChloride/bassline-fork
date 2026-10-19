## Blocks, and the work they show.
##
##   (block PREV BITS [SPEND …] NONCE)
##
## PREV is the id of the block it follows, nil for the first. A block
## shows its work when the hash of its id begins with BITS zero bits,
## BITS no fewer than MinBits, and it counts 2^BITS of work. The first
## block holds the unsigned genesis transaction and shows no work: it
## is never judged, only held from the start.

import std/[algorithm, bitops, sequtils]
import ./coin
export coin

const MinBits* = 8

proc zeros(h: Hash): int =
  for b in h:
    if b != 0: return result + countLeadingZeroBits(b)
    result += 8

proc isBlock*(v: Value): bool =
  v.isKind(bRec, unmarked) and v.len == 5 and v.head == bl"block" and
    (v[1].isKind(bNil) or Digest.fits(v[1])) and
    v[2].isKind(bNum, unmarked) and v[2].num.isInt and
    v[2].num.toInt in MinBits .. 32 and
    v[3].isKind(bList, unmarked) and v[3].items.data.allIt(it.isSpend) and
    v[4].isKind(bNum, unmarked)

proc showsWork*(v: Value): bool =
  v.digest(Blake2bAlgo).hash.zeros >= v[2].num.toInt

proc work*(v: Value): int = 1 shl v[2].num.toInt

proc firstBlock*(genesis: Value): Value = bl"(block nil 0 [$genesis] 0)"

proc grind*(prev: Value, bits: int, spends: openArray[Value]): Value =
  ## the first block over these that shows `bits` of work
  var nonce = 0
  while true:
    result = bl"(block $prev $bits $spends $nonce)"
    if result.showsWork: return
    inc nonce

proc branch*(blocks: BDict, id: Value): seq[Value] =
  ## the blocks from the first to the one named id, oldest first
  var at = id
  while not at.isKind(bNil):
    result.add blocks[at]
    at = blocks[at][1]
  result.reverse
