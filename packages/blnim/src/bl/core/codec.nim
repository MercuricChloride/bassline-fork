## This module deals with ce bytes alongside their encoding & decoding.
## 
## Validation of ce bytes is split into two passes:
## 
## 1. Shape validation
## 
## This step validates that tags & marks are valid, atoms have
## minimal length tiers, END bytes are balanced etc.
## This is all checked by `scan` on the way in
## 
## 2. Content validation
## 
## This step validates that ints have valid spellings, utf8
## representation is correct, sets & dicts are ascending.
## This is invoked by `finalize` when encoding, and `judge` when decoding.
## 
## We expose 2 objects for working with this: `Encoder` and `Decoder`.
## 
## The `Encoder` owns it's byte buffer, but `Decoder` does not.
## It's very important that you don't mutate the decoders buffer randomly
## because all of the offsets are specific to that buffer.
## 
## An `Encoder`:
## Accumulates spans as we write to it so
## finalize never has to re parse. `scan` produces the same
## preorder span list from wire bytes. Spans carry payload offsets, so
## downstream consumers (materializers, extractors, payload-law
## buckets) never touch a header byte.
##
## Two doors on the way in. The bare `scan`/`judge(data, ...)` gate a
## whole buffer: one value, nothing before or after.
##
## A `Decoder` reads
## values one at a time out of a stream that is still arriving: it
## holds the spans of the value in progress, its open frames, and the
## read head, and its `scan`/`judge` answer false -- not a refusal --
## while the bytes so far are only a prefix. Refusals are prefix-closed:
## nothing scan refuses could be repaired by more bytes.
##
## Encoder and Decoder are reusable: reset keeps the buffer and span
## capacities, so steady-state encoding and decoding don't re-allocate

from std/bitops import countTrailingZeroBits
from std/endians import littleEndian64

const
  MaxDepth {.intdefine.} = 64
  MaxPayload = uint32.high
  EndByte: byte = 0xA0
  MarkBit: byte = 0x08

type
  ValueTag* {.size: 1.} = enum
    vNil = 1,
    vNum, vText, vSym, vBytes,
    vList, vRec, vDict, vSet

  Span* = object
    lo*, hi*, payLo*, count*: int
    # lo, hi is the whole value span
    # payload starts at payLo
    # and count represents how many children a frame has
    kind*: ValueTag
    marked*: bool
    # kind and mark are brought along so we don't have to deref the header byte

  Encoder* = object
    buf*: seq[byte]
    spans*: seq[Span]
    stack: seq[int]
    ## spans indices of open frames

  Decoder* = object
    ## a reading in progress over a growing stream of bytes: the spans
    ## of the value being read, its open frames, and the read head
    spans*: seq[Span]
    stack: seq[int]
    ## spans indices of open frames
    pos*: int
    ## where the next unit starts; after a whole
    ## value, where it ends

  CodecError* = object of CatchableError

const
  ScalarTags* = {vNum, vText, vSym, vBytes}
  FrameTags* = {vList, vRec, vDict, vSet}

template refuse(msg: string) =
  raise newException(CodecError, msg)

template guard(cond: bool, msg: string) =
  if not cond: refuse(msg)

template ensure(cond) =
  result = cond
  if not result: return

# ================ Encoding ================

func initEncoder*(cap = 256): Encoder =
  Encoder(buf: newSeqOfCap[byte](cap), spans: newSeqOfCap[Span](32))

func reset*(e: var Encoder) =
  e.buf.setLen 0
  e.spans.setLen 0
  e.stack.setLen 0

func putHeader(e: var Encoder, kind: ValueTag, marked: bool, n: int) {.inline.} =
  let m = if marked: MarkBit else: 0'u8
  if n < 7:
    e.buf.add (kind.byte shl 4) or m or byte(n)
  elif n < 255:
    e.buf.add (kind.byte shl 4) or m or 7'u8
    e.buf.add byte(n)
  else:
    e.buf.add (kind.byte shl 4) or m or 7'u8
    e.buf.add 0xFF'u8
    for shift in [24, 16, 8, 0]:
      e.buf.add byte((n shr shift) and 0xFF)

func putScalar*(e: var Encoder, kind: ValueTag, payload: openArray[byte],
                marked = false) =
  doAssert kind in ScalarTags, "not a scalar kind"
  doAssert payload.len <= MaxPayload.int, "payload exceeds u32 cap"
  let lo = e.buf.len
  e.putHeader(kind, marked, payload.len)
  let payLo = e.buf.len
  e.buf.add payload
  e.spans.add Span(lo: lo, payLo: payLo, hi: e.buf.len,
                   kind: kind, marked: marked)

func putNil*(e: var Encoder, marked = false) =
  let lo = e.buf.len
  e.putHeader(vNil, marked, 0)
  e.spans.add Span(lo: lo, payLo: e.buf.len, hi: e.buf.len,
                   kind: vNil, marked: marked)

func putNum*(e: var Encoder, i: int64, marked = false) =
  let d = $i
  e.putScalar(vNum, d.toOpenArrayByte(0, d.high), marked)

func putText*(e: var Encoder, s: string, marked = false) =
  e.putScalar(vText, s.toOpenArrayByte(0, s.high), marked)

func putSym*(e: var Encoder, s: string, marked = false) =
  e.putScalar(vSym, s.toOpenArrayByte(0, s.high), marked)

func putBytes*(e: var Encoder, b: openArray[byte], marked = false) =
  e.putScalar(vBytes, b, marked)

func putOpen*(e: var Encoder, kind: ValueTag, marked = false) =
  doAssert kind in FrameTags, "not a frame kind"
  # same law scan enforces: refuse (not assert) — depth comes from data
  guard e.stack.len < MaxDepth, "nesting deeper than MaxDepth"
  let lo = e.buf.len
  e.putHeader(kind, marked, 0)
  e.stack.add e.spans.len
  e.spans.add Span(lo: lo, payLo: e.buf.len, kind: kind, marked: marked)

func putClose*(e: var Encoder) =
  doAssert e.stack.len > 0, "close with no open frame"
  e.buf.add EndByte
  let i = e.stack.pop()
  e.spans[i].hi = e.buf.len
  e.spans[i].count = e.spans.len - i - 1

template frame*(e: var Encoder, kind: ValueTag, body: untyped) =
  e.putOpen(kind)
  body
  e.putClose()

# ================ Byte order ================

func cmpBytes*(a, b: openArray[byte]): int =
  let n = min(a.len, b.len)
  if n > 0:
    let r = cmpMem(addr a[0], addr b[0], n)
    if r != 0: return r
  a.len - b.len

# ================ Payload laws ================

func isValidInt*(bytes: openArray[byte]): bool =
  ensure bytes.len > 0
  let start = if bytes[0] == '-'.byte: 1 else: 0
  ensure bytes.len > start                    # bare "-" refused
  if bytes[start] == '0'.byte:
    ensure start == 0                         # "-0" refused
    ensure bytes.len == 1                     # leading zeros refused
  for i in start ..< bytes.len:
    ensure bytes[i].char in {'0'..'9'}

# HEADS UP NOT MY CODE!
# Original DFA Table credit is
# Copyright (c) 2008-2010 Bjoern Hoehrmann <bjoern@hoehrmann.de>
# See http://bjoern.hoehrmann.de/utf-8/decoder/dfa/ for details.
const
  UTF8_ACCEPT = 0
  UTF8_REJECT = 12

  utf8d: array[364, uint8] = [
    # The first part of the table maps bytes to character classes that
    # to reduce the size of the transition table and create bitmasks.
    0'u8,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
    8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3,11,6,6,6,5,8,8,8,8,8,8,8,8,8,8,8,
    # The second part is a transition table that maps a combination
    # of a state of the automaton and a character class to a state.
    0,12,24,36,60,96,84,12,12,12,48,72,
    12,12,12,12,12,12,12,12,12,12,12,12,
    12, 0,12,12,12,12,12, 0,12, 0,12,12,
    12,24,12,12,12,12,12,24,12,24,12,12,
    12,12,12,12,12,12,12,24,12,12,12,12,
    12,24,12,12,12,12,12,12,12,24,12,12,
    12,12,12,12,12,12,12,36,12,36,12,12,
    12,36,12,12,12,12,12,36,12,36,12,12,
    12,36,12,12,12,12,12,12,12,12,12,12
  ]

func isValidUtf8*(bytes: openArray[byte]): bool =
  ## ASCII runs are skipped a word at a time, jumping straight to the
  ## first high byte; the DFA only ever touches non-ASCII sequences.
  ## The word is loaded little-endian on every host, so the first byte
  ## in memory is the low lane and the lowest set bit of the mask is
  ## the first high byte.
  var state = UTF8_ACCEPT
  var i = 0
  let n = bytes.len
  while i < n:
    if state == UTF8_ACCEPT:
      while i + 8 <= n:
        var w: uint64
        littleEndian64(addr w, addr bytes[i])
        let hi = w and 0x8080808080808080'u64
        if hi != 0:
          i += countTrailingZeroBits(hi) shr 3
          break
        i += 8
      while i < n and bytes[i] < 0x80:
        inc i
      if i >= n: break
    let byteClass = utf8d[bytes[i]]
    state = int(utf8d[256 + state + int(byteClass)])
    if state == UTF8_REJECT:
      return false
    inc i
  state == UTF8_ACCEPT

func validate*(buf: openArray[byte], spans: openArray[Span]) =
  ## Validates spans against the buf enforcing all constraints
  ## in one pass
  for i in 0 ..< spans.len:
    let s = spans[i]
    case s.kind
    of vNum:
      guard isValidInt(buf.toOpenArray(s.payLo, s.hi - 1)),
        "malformed integer spelling"
    of vText, vSym:
      guard isValidUtf8(buf.toOpenArray(s.payLo, s.hi - 1)),
        "ill-formed UTF-8 in text"
    of vRec:
      guard s.count > 0, "record with no head"
    of vSet:
      var prev = -1
      var j = i + 1
      while j <= i + s.count:
        if prev >= 0:
          guard cmpBytes(buf.toOpenArray(spans[prev].lo, spans[prev].hi - 1),
                         buf.toOpenArray(spans[j].lo, spans[j].hi - 1)) < 0,
            "set members not strictly ascending"
        prev = j
        j += spans[j].count + 1
    of vDict:
      var prevKey = -1
      var kids = 0
      var j = i + 1
      while j <= i + s.count:
        if kids mod 2 == 0:
          if prevKey >= 0:
            guard cmpBytes(buf.toOpenArray(spans[prevKey].lo, spans[prevKey].hi - 1),
                           buf.toOpenArray(spans[j].lo, spans[j].hi - 1)) < 0,
              "dict keys not strictly ascending"
          prevKey = j
        inc kids
        j += spans[j].count + 1
      guard kids mod 2 == 0, "dict with dangling key"
    else:
      discard

func finalize*(e: sink Encoder): seq[byte] =
  ## validates the encoders buffer + spans into a validated buffer
  guard e.stack.len == 0, "unclosed frame"
  validate(e.buf, e.spans)
  move e.buf

# ================ Decoding ================

func reset*(d: var Decoder) =
  d.spans.setLen 0
  d.stack.setLen 0
  d.pos = 0

func scanFrom(data: openArray[byte], spans: var seq[Span],
              stack: var seq[int], pos: var int): bool =
  ## The shape pass, resumable: minimal length forms, balanced frames,
  ## bounded depth, and the span list as a byproduct. With no frame
  ## open it begins a value at `pos`, otherwise it continues the one in
  ## progress. True when a whole value has been read (it ends at
  ## `pos`); false when `data` ran out first -- a prefix is not yet a
  ## judgment: call again once `data` has grown (the same bytes,
  ## extended). Malformation refuses, and no extension of a refused
  ## prefix could have been well-formed. Content laws are `validate`'s.
  guard pos <= data.len, "the stream shrank"
  if stack.len == 0: spans.setLen 0
  while true:
    if pos >= data.len: return false
    let h = data[pos]
    var next = pos + 1      # a unit commits to pos only once it is whole
    if h == EndByte:
      guard stack.len > 0, "stray END with no open frame"
      let i = stack.pop()
      spans[i].hi = next
      spans[i].count = spans.len - i - 1
    else:
      let tag = int(h shr 4)
      guard tag in 1 .. 9, "invalid tag " & $tag
      let
        kind = ValueTag(tag)
        marked = (h and MarkBit) != 0
        lbits = int(h and 7)
      if kind == vNil:
        guard lbits == 0, "nil with length bits"
        spans.add Span(lo: pos, payLo: next, hi: next, kind: kind, marked: marked)
      elif kind in FrameTags:
        guard lbits == 0, "frame with length bits"
        guard stack.len < MaxDepth, "nesting deeper than MaxDepth"
        stack.add spans.len
        spans.add Span(lo: pos, payLo: next, kind: kind, marked: marked)
        pos = next
        # frame still open
        continue
      else:
        var n = lbits
        if n == 7:
          if next >= data.len: return false
          n = int(data[next])
          inc next
          if n == 255:
            if next + 4 > data.len: return false
            n = 0
            for _ in 0 ..< 4:
              n = (n shl 8) or int(data[next])
              inc next
            guard n >= 255, "non-minimal u32 length tier"
          else:
            guard n >= 7, "non-minimal u8 length tier"
        if data.len - next < n: return false
        spans.add Span(lo: pos, payLo: next, hi: next + n,
                       kind: kind, marked: marked)
        next += n
    pos = next
    if stack.len == 0: return true

func scan*(data: openArray[byte], spans: var seq[Span]) =
  ## one whole value and nothing else: the shape gate for a buffer
  var stack = newSeqOfCap[int](MaxDepth)
  var pos = 0
  guard scanFrom(data, spans, stack, pos), "truncated value"
  guard pos == data.len, "trailing bytes after value"

func scan*(d: var Decoder, data: openArray[byte]): bool =
  ## the next whole value out of a stream, or not yet
  scanFrom(data, d.spans, d.stack, d.pos)

func judge*(data: openArray[byte], spans: var seq[Span]) =
  ## This simply composes scan + validate to enforce structural
  ## constraints + content constraints
  scan(data, spans)
  validate(data, spans)

func judge*(d: var Decoder, data: openArray[byte]): bool =
  ## the next whole, valid value out of a stream, or not yet
  result = d.scan(data)
  if result: validate(data, d.spans)

func judge*(data: openArray[byte]) =
  var spans: seq[Span]
  judge(data, spans)