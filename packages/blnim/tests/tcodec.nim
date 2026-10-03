## the codec against the corpus: a decoder fed a value one byte at a
## time waits and never refuses until the last byte lands it, and
## bytes a decoder must reject are rejected however they arrive.
## Random values survive encoding, alone and concatenated.

import std/unittest
from std/sequtils import repeat, mapIt
import bl/core
import bl/lib/blah
import ./corpus

type Turns = object
  ## what a decoder fed in turns landed, as values, since a compact
  ## leaves earlier views behind
  values: seq[Value]
  pending, refused: bool
  why: string
  peak: int   # the most bytes the buffer held at once

proc inTurns(bytes: openArray[byte], cuts: openArray[int],
             cap = MaxValueBytes): Turns =
  ## bytes fed a turn at a time, each turn ending at the next cut and
  ## the last at the end, drained whole and then compacted
  var d = newDecoder(maxValueBytes = cap)
  var lo = 0
  try:
    for hi in @cuts & bytes.len:
      d.buf.add bytes.toOpenArray(lo, hi - 1)
      lo = hi
      result.peak = max(result.peak, d.buf.len)
      for v in d.checked:
        result.values.add v.toValue
      d.compact()
  except CodecError as e:
    result.refused = true
    result.why = e.msg
  result.pending = d.pending

template landsAlike(bytes: openArray[byte], cuts: openArray[int]) =
  ## fed in turns with a compact after each, bytes land the same
  ## values, or are refused for the same reason, as when they arrive
  ## whole
  let
    whole = land(bytes)
    turns = inTurns(bytes, cuts)
  check turns.values == whole.values.mapIt(it.toValue)
  check turns.refused == whole.refused
  check turns.why == whole.why
  if not whole.refused:
    check turns.pending == whole.pending

suite "one byte at a time":
  filter "ce", c:
    let
      name = c.items[1].text
      value = c.items[2]
      bytes = c.items[3].bytes
    test name:
      var d = newDecoder()
      var landed: seq[Value]
      for i, b in bytes:
        d.buf.add b
        for v in d.checked:
          landed.add v.toValue
        if i < bytes.high:
          check landed.len == 0
          check d.pending
      check landed.len == 1
      if landed.len == 1:
        check landed[0] == value
      check not d.pending

  filter "reject", c:
    let
      name = c.items[1].text
      bytes = c.items[2].bytes
    test name:
      var d = newDecoder()
      expect CodecError:
        for b in bytes:
          d.buf.add b
          for v in d.checked: discard

suite "one value, given in total":
  filter "starved", c:
    let bytes = c.items[2].bytes
    test "a prefix is refused: " & c.items[1].text:
      expect CodecError: discard Value.decode(bytes)
      expect CodecError: discard Value.decode(ce(num 1) & bytes)
      var landed = 0
      for v in Value.decode(bytes): inc landed   # the iterator just waits
      check landed == 0

  test "no value, or two, is refused":
    expect CodecError: discard Value.decode(newSeq[byte]())
    expect CodecError: discard Value.decode(ce(num 1) & ce(num 2))
    check Value.decode(ce(num 1)) == num 1

suite "value size cap":
  const cap = 4096
  proc decoded(bytes: openArray[byte]): seq[Value] =
    var d = newDecoder(maxValueBytes = cap)
    d.buf.add bytes
    for v in d.checked: result.add v.toValue

  test "a scalar header over the cap is refused before any payload":
    let full = ce(bytes(newSeq[byte](cap + 1)))
    let header = full[0 ..< full.len - cap - 1]      # no payload behind it
    expect CodecError: discard decoded(header)

  test "a frame that never closes is refused once it holds over the cap":
    let stream = ce(initList())[0 ..< ^1] & # a list header, no END
                 repeat(ce(null())[0], cap) # one-byte members, over the cap
    expect CodecError: discard decoded(stream)

  test "a value at the cap decodes":
    let v = bytes(newSeq[byte](cap div 2))
    check decoded(ce(v)) == @[v]

suite "random values":
  var values: seq[Value]
  for _ in 0 ..< 80:
    values.add randValue(3)

  test "encode then decode":
    for v in values:
      let l = land(v.ce)
      check not l.refused
      check l.values.len == 1
      if l.values.len == 1:
        check l.values[0].toValue == v

  test "many values on one buffer":
    let enc = newEncoder()
    for v in values:
      enc.write v
    let l = land(enc.bytes)
    check not l.refused
    check not l.pending
    check l.values.len == values.len
    for i in 0 ..< min(l.values.len, values.len):
      check l.values[i].toValue == values[i]

# compact drops what the decoder has finished with, even inside a
# frame still open, so a long run of input stays bounded by the value
# in progress and the turn that just arrived

suite "compact":
  proc stream(vals: openArray[Value]): seq[byte] =
    let enc = newEncoder()
    for v in vals:
      enc.write v
    @(enc.bytes)

  proc largest(vals: openArray[Value]): int =
    for v in vals:
      result = max(result, v.ce.len)

  test "a long run in small chunks stays bounded and lands the same values":
    var values: seq[Value]
    for _ in 0 ..< 200:
      values.add randValue(3)
    let bytes = stream(values)
    for size in [1, 7, 61, 4096]:
      checkpoint("chunk " & $size)
      let t = inTurns(bytes, every(size, bytes.len))
      check not t.refused
      check not t.pending
      check t.values == values
      check t.peak < largest(values) + size

  test "small records whose ends never meet a chunk boundary":
    # one byte up front, then records of fourteen bytes: every record
    # ends at an odd offset and every chunk at an even one
    var values = @[null()]
    for i in 1000 ..< 9000:
      values.add initRec(@[sym"person", num(i)])
    let bytes = stream(values)
    let t = inTurns(bytes, every(64, bytes.len))
    check not t.refused
    check t.values == values
    check t.peak < largest(values) + 64

  filter "ce", c:
    let
      name = c.items[1].text
      value = c.items[2]
      around = @[initRec(@[sym"before"]), value, initList(@[sym"after"])]
      bytes = stream(around)
    test "every cut of " & name:
      # a value before gives each compact something to drop while the
      # case's frames are open with members attached
      for cut in 0 .. bytes.len:
        checkpoint("cut " & $cut)
        let t = inTurns(bytes, [cut])
        check t.values == around
        check not t.pending
        check t.peak <= bytes.len
      check inTurns(bytes, every(1, bytes.len)).values == around

  test "every cut of random nested values":
    var n = 0
    while n < 40:
      let v = randValue(4)
      if v.kind notin {bList, bRec, bDict, bSet} or v.ce.len > 2000: continue
      inc n
      let
        around = @[initRec(@[sym"before"]), v]
        bytes = stream(around)
      for cut in 0 .. bytes.len:
        let t = inTurns(bytes, [cut])
        check t.values == around

  filter "reject", c:
    let
      name = c.items[1].text
      bad = c.items[2].bytes
      before = stream([initRec(@[sym"before"])])
      member = stream([initList(@[num(1), text"two"])])
    test "refused alike in turns: " & name:
      # alone after a value, and inside a list that is open when the
      # turns are compacted
      let inside = before & @[0x60'u8] & member & bad & @[EndByte]
      for bytes in [before & bad, inside]:
        for cut in 0 .. bytes.len:
          checkpoint("cut " & $cut)
          landsAlike(bytes, [cut])
        landsAlike(bytes, every(1, bytes.len))

  test "a refusal after a compact inside the frame keeps its reason":
    let open = stream([initRec(@[sym"before"])]) & @[0x60'u8] &
               stream([num(1), initList(@[num(2)])])
    for (tail, why) in [(@[0x22'u8, 0x2d, 0x30, EndByte], "malformed number"),
                        (@[0x80'u8, 0x41, 0x61, EndByte, EndByte],
                         "dict cannot have stranded keys"),
                        (@[0x90'u8, 0x41, 0x62, 0x41, 0x61, EndByte, EndByte],
                         "set elements must be strictly ascending")]:
      let bytes = open & tail
      for cut in 0 .. bytes.len:
        let t = inTurns(bytes, [cut])
        check t.refused
        check t.why == why
        check t.values == @[initRec(@[sym"before"])]

  test "the value-size cap counts from the open frame, compacted or not":
    const cap = 4096
    let
      before = stream(repeat(initRec(@[sym"before"]), cap))  # more than cap
      header = ce(initList())[0 ..< ^1]
      atCap = before & header & repeat(ce(null())[0], cap - 1)
    let held = inTurns(atCap, every(100, atCap.len), cap)
    check not held.refused
    check held.pending
    check held.values.len == cap
    check held.peak < cap + 100
    let over = inTurns(atCap & ce(null()), every(100, atCap.len), cap)
    check over.refused
    check over.why == "unclosed frame exceeds the value-size cap"
