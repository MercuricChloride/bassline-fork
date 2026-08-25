## codec.nim — the wire layer: canonical CE bytes in and out.
##
## The laws live in exactly two places, and nothing else may re-derive
## header math (that invariant is what keeps validation single-sourced):
##
##   * SHAPE laws (tags, mark bits, minimal length tiers, END balance,
##     truncation) — unviolable by construction on the way out (the
##     emitter owns the header math); checked by `scan` on the way in,
##     which also builds the span list.
##   * CONTENT laws (int spellings, UTF-8, set order/dedup, dict
##     parity/key order) — ONE function, `validate(buf, spans)`,
##     invoked by finalize (encode) and judge (decode) alike.
##
## The Encoder accumulates spans as a byproduct of writing (a frame's
## span is pushed as a placeholder at open and patched at close), so
## finalize never re-parses its own output. `scan` produces the same
## preorder span list from wire bytes. Spans carry payload offsets, so
## downstream consumers (materializers, extractors, payload-law
## buckets) never touch a header byte.
##
## Both Encoder and Decoder are reusable scratch: reset/judge keep the
## buffer and span capacities, so steady-state encoding and decoding
## allocate nothing.

import std/bitops

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
    lo*, hi*, payLo*, count*: int   # [lo, hi) whole spelling; payload at payLo
    kind*: ValueTag
    marked*: bool

  Encoder* = object
    buf*: seq[byte]
    spans*: seq[Span]
    stack: seq[int]         # spans indices of open frames

  Decoder* = object
    spans*: seq[Span]

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
  var state = UTF8_ACCEPT
  var i = 0
  let n = bytes.len
  while i < n:
    if state == UTF8_ACCEPT:
      while i + 8 <= n:
        var w: uint64
        copyMem(addr w, addr bytes[i], 8)
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

func scan*(data: openArray[byte], spans: var seq[Span]) =
  ## Enforces shape constraints and builds a span list 
  ## from untrusted bytes.
  ## This checks minimal length forms, balanced frames,
  ## bounded depth.
  ## This does !NOT! enforce content validation, `validate`
  ## does that. You can use `judge` which composes the two.
  spans.setLen 0
  var stack = newSeqOfCap[int](MaxDepth)
  var pos = 0
  while true:
    guard pos < data.len, "truncated: expected a value"
    let h = data[pos]
    if h == EndByte:
      guard stack.len > 0, "stray END with no open frame"
      inc pos
      let i = stack.pop()
      spans[i].hi = pos
      spans[i].count = spans.len - i - 1
      if stack.len == 0: break
    else:
      let tag = int(h shr 4)
      guard tag in 1 .. 9, "invalid tag " & $tag
      let
        kind = ValueTag(tag)
        marked = (h and MarkBit) != 0
        lbits = int(h and 7)
        lo = pos
      inc pos
      if kind == vNil:
        guard lbits == 0, "nil with length bits"
        spans.add Span(lo: lo, payLo: pos, hi: pos, kind: kind, marked: marked)
      elif kind in FrameTags:
        guard lbits == 0, "frame with length bits"
        guard stack.len < MaxDepth, "nesting deeper than MaxDepth"
        stack.add spans.len
        spans.add Span(lo: lo, payLo: pos, kind: kind, marked: marked)
        # frame still open
        continue
      else:
        var n = lbits
        if n == 7:
          guard pos < data.len, "truncated u8 length"
          n = int(data[pos])
          inc pos
          if n == 255:
            guard pos + 4 <= data.len, "truncated u32 length"
            n = 0
            for _ in 0 ..< 4:
              n = (n shl 8) or int(data[pos])
              inc pos
            guard n >= 255, "non-minimal u32 length tier"
          else:
            guard n >= 7, "non-minimal u8 length tier"
        guard data.len - pos >= n, "truncated payload"
        spans.add Span(lo: lo, payLo: pos, hi: pos + n,
                       kind: kind, marked: marked)
        pos += n
      if stack.len == 0: 
        # completed a top-level value
        break
  guard pos == data.len, "trailing bytes after value"

func judge*(data: openArray[byte], spans: var seq[Span]) =
  ## This simply composes scan + validate to enforce structural
  ## constraints + content constraints
  scan(data, spans)
  validate(data, spans)

func judge*(d: var Decoder, data: openArray[byte]) =
  judge(data, d.spans)

func judge*(data: openArray[byte]) =
  var spans: seq[Span]
  judge(data, spans)

# ================ Self-test ================

when isMainModule:
  proc ok(data: openArray[byte]) =
    var spans: seq[Span]
    judge(data, spans)

  proc bad(data: openArray[byte], why: string) =
    var spans: seq[Span]
    try:
      judge(data, spans)
      doAssert false, "accepted non-canonical input: " & why
    except CodecError:
      discard

  # encode → judge round trips (finalize and judge agree on validity)
  block:
    var e = initEncoder()
    e.putNil()
    ok e.finalize()
  for i in [0'i64, -1, 9, 10, high(int64), low(int64)]:
    var e = initEncoder()
    e.putNum(i)
    ok e.finalize()
  block:
    var e = initEncoder()
    e.putText("héllo wörld ☃ 🐍", marked = true)
    ok e.finalize()
  for n in [0, 1, 6, 7, 8, 254, 255, 256, 70_000]:  # tier boundaries
    var e = initEncoder()
    var s = newString(n)
    for i in 0 ..< n: s[i] = 'x'
    e.putText(s)
    ok e.finalize()
  block:                                      # nesting + span navigation
    var e = initEncoder()
    e.frame vRec:
      e.putSym("msg")
      e.putNum(42)
      e.frame vList:
        e.putText("x")
    doAssert e.spans[0].count == 4            # rec spans its whole subtree
    doAssert e.spans[3].count == 1            # the list holds one child
    ok e.finalize()
  block:                                      # sorted set: shortlex order
    var e = initEncoder()
    e.frame vSet:
      e.putNum(1)
      e.putNum(2)
      e.putNum(10)
    ok e.finalize()
  block:                                      # empty set and empty dict
    var e = initEncoder()
    e.frame vSet: discard
    e.frame vDict: discard
    doAssert e.stack.len == 0
    validate(e.buf, e.spans)                  # scratch-reuse door
  block:                                      # sorted dict
    var e = initEncoder()
    e.frame vDict:
      e.putSym("a"); e.putNum(1)
      e.putSym("b"); e.putNum(2)
    ok e.finalize()

  # finalize IS the encode-side law: violations built with the same
  # puts are caught at the single point
  proc badEnc(e: sink Encoder, why: string) =
    try:
      discard finalize(e)
      doAssert false, "finalize accepted: " & why
    except CodecError:
      discard
  block:
    var e = initEncoder()
    e.frame vSet:
      e.putNum(2)
      e.putNum(1)
    badEnc e, "unsorted set"
  block:
    var e = initEncoder()
    e.frame vSet:
      e.putNum(3)
      e.putNum(3)
    badEnc e, "duplicate set member"
  block:
    var e = initEncoder()
    e.frame vDict:
      e.putSym("b"); e.putNum(1)
      e.putSym("a"); e.putNum(2)
    badEnc e, "unsorted dict keys"
  block:
    var e = initEncoder()
    e.frame vDict:
      e.putSym("a")
    badEnc e, "dangling dict key"
  block:
    var e = initEncoder()
    e.putText("\xFF")
    badEnc e, "ill-formed UTF-8 through putText"

  # canonicality rejections off the wire
  bad @[0x00'u8], "tag 0"
  bad @[0xA0'u8], "stray END"
  bad @[0xF0'u8], "tag > 9"
  bad @[0x11'u8], "nil with length bits"
  bad @[0x61'u8, 0xA1], "frame with length bits"
  bad @[0x60'u8], "unclosed frame"
  bad @[0x37'u8, 0x03, byte('a'), byte('b'), byte('c')],
      "u8 tier spelling of len 3"
  bad @[0x37'u8, 0xFF, 0, 0, 0, 200] & newSeq[byte](200),
      "u32 tier spelling of len 200"
  bad @[0x22'u8, byte('0'), byte('7')], "leading zero"
  bad @[0x22'u8, byte('-'), byte('0')], "-0"
  bad @[0x21'u8, byte('x')], "non-digit integer"
  bad @[0x20'u8], "empty integer"
  ok  @[0x21'u8, byte('0')]                   # "0" is canonical
  bad @[0x33'u8, byte('h'), byte('i')], "truncated payload"
  bad @[0x31'u8, 0xFF], "0xFF in str"
  bad @[0x42'u8, 0xC0, 0x80], "overlong NUL in sym"
  bad @[0x33'u8, 0xED, 0xA0, 0x80], "surrogate in str"
  ok  @[0x51'u8, 0xFF]                        # same byte fine as vBytes
  block:
    var e = initEncoder()
    e.putText("ok")
    bad e.finalize() & @[0x00'u8], "trailing bytes"
  block:                                      # depth bomb refused, not crashed
    var raw: seq[byte]
    for _ in 0 .. MaxDepth: raw.add 0x60'u8
    bad raw, "nesting deeper than MaxDepth"
  block:                                      # encoder refuses the same law
    var e = initEncoder()
    try:
      for _ in 0 .. MaxDepth: e.putOpen(vList)
      doAssert false, "encoder nested past MaxDepth"
    except CodecError:
      discard
  block:                                      # exactly MaxDepth: both doors agree
    var e = initEncoder()
    for _ in 0 ..< MaxDepth: e.putOpen(vList)
    for _ in 0 ..< MaxDepth: e.putClose()
    ok e.finalize()

  # the mark participates in the spelling (twins differ in one bit)
  block:
    var p = initEncoder(); p.putSym("x")
    var m = initEncoder(); m.putSym("x", marked = true)
    let a = p.finalize()
    let b = m.finalize()
    doAssert a != b and (a[0] xor b[0]) == MarkBit

  echo "codec: all tests passed"
