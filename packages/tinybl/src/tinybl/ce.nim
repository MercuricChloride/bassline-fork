from std/bitops import countTrailingZeroBits
import std/[options, streams]
export options

when not defined(js):
  from std/endians import littleEndian64

const
  MaxDepth* {.intdefine.} = 64
  MaxValueBytes* {.intdefine.} = 100 * 1024 * 1024
    ## the most bytes a reader takes for one value: an atom that would
    ## pass it, or a frame that reaches it before it closes, is refused
    ## rather than held. CE tops out at ~4.3GB, so a receiver draws the
    ## line lower at its boundary.
  MaxPayload* = uint32.high
  EndByte*: byte = 0xA0
  MarkBit*: byte = 0x08

type
  BasslineError* = object of ValueError
  CodecError* = object of BasslineError

# ================
# Error utils
# ================

template refuseWith*(err) {.dirty.} =
  ## gives a module its own `refuse msg`, raising `err`, and `guard cond`,
  ## refusing unless cond holds. Both are bound where they are written,
  ## so a generic proc refuses with its own module's error wherever it
  ## is instantiated.
  template refuse(msg: string) =
    raise newException(err, msg)

  template guard(cond: untyped, msg: string) =
    if not(cond):
      refuse(msg)

refuseWith CodecError

# ================
# Kind & tag parsing
# ================

type
  Kind* = enum
    bNil,
    bNum, bText, bSym, bBytes,
    bList, bRec, bDict, bSet

func tag*(kind: Kind): byte =
  byte(kind.ord + 1)

func parseTag*(b: byte): Kind =
  Kind(b - 1)

func `$`*(kind: Kind): string =
  case kind
  of bNil: "nil"
  of bNum: "number"
  of bText: "text"
  of bSym: "symbol"
  of bBytes: "bytes"
  of bList: "list"
  of bRec: "record"
  of bDict: "dict"
  of bSet: "set"

func parseKind*(s: string): Option[Kind] =
  case s
  of "nil": some bNil
  of "number": some bNum
  of "text": some bText
  of "symbol": some bSym
  of "bytes": some bBytes
  of "list": some bList
  of "record": some bRec
  of "dict": some bDict
  of "set": some bSet
  else: none Kind

# ================
# Codec Utils
# ================

func headerData*(b: byte): tuple[kind: Kind, mark: bool, inlineLen: int] =
  let
    tag = int(b shr 4)
    mark = (b and MarkBit) != 0
    len = int(b and 7)
  guard tag in 1..9, ("invalid tag: " & $tag)
  (Kind(tag - 1), mark, len)

type
  PartialValueKind* = enum
    pvNil, pvAtom, pvOpenFrame, pvCloseFrame

func partialKind*(b: byte): PartialValueKind =
  if b == EndByte:
    return pvCloseFrame
  let h = headerData(b)
  case h.kind
  of bNum..bBytes: 
    pvAtom
  of bNil:
    guard h.inlineLen == 0, "nil lenBits must be 0"
    pvNil
  of bList..bSet:
    guard h.inlineLen == 0, "frame lenBits must be 0"
    pvOpenFrame

# ================
# String & bytes support
# ================

template toBytes*(a: string): openArray[byte] =
  a.toOpenArrayByte(0, a.high)

# ================
# CE comparisons
# ================

func cmpBytes*(a, b: openArray[byte]): int =
  let n = min(a.len, b.len)
  when defined(js):
    for i in 0 ..< n:
      if a[i] != b[i]: return int(a[i]) - int(b[i])
  else:
    when nimvm:
      for i in 0 ..< n:
        if a[i] != b[i]: return int(a[i]) - int(b[i])
    else:
      if n > 0:
        let r = cmpMem(addr a[0], addr b[0], n)
        if r != 0: return r
  a.len - b.len

func cmpShortlex*(x, y: string): int =
  result = cmp(x.len, y.len)
  if result != 0: return
  result = cmpBytes(x.toBytes, y.toBytes)

# ================
# Int & utf8 validation
# ================

func isValidInt*(bytes: openArray[byte]): bool =
  if bytes.len == 0: 
    return false
  let start = if bytes[0] == '-'.byte: 1 else: 0
  if bytes.len <= start:
     # bare "-" refused
    return false
  if bytes[start] == '0'.byte:
    if start != 0: return false
    if bytes.len != 1: return false
  for i in start ..< bytes.len:
    if bytes[i].char notin {'0'..'9'}:
      return false
  true

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
      when not defined(js):
        when nimvm:
          discard
        else:
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

# ================
# Stream Concepts
# ================

type
  Readable* = concept
    proc null(T: typedesc[Self], mark: bool): Self
    proc atom(T: typedesc[Self], bytes: sink string, kind: Kind, mark: bool): Self
    proc frame(T: typedesc[Self], members: sink seq[Self], kind: Kind, mark: bool): Self
    
  Editable* = concept
    proc setMark(self: var Self, mark: bool)

  Walkable* = concept
    ## Walkable is a concept for an object
    ## that supports traversal as though it
    ## were an encoded bassline value with
    ## correct ce structure.
    ## 
    ## payload & digits should return binary 
    ## strings being the payload of an atom
    ## 
    ## children are the constituents of frames
    ## and for dicts it is expected to alternate
    ## K V K V
    ## Same goes with getChild. foo.getChild(1) should
    ## return the first key in the dict
    proc valid(self: Self): bool
    proc kind(self: Self): Kind
    proc mark(self: Self): bool
    proc digits(self: Self): string
    proc payload(self: Self): string
    proc len(self: Self): int
    proc getChild(self: Self, idx: int): Self
    iterator children(self: Self): Self

# ================
# Stream Reading
# ================

type
  OpenFrame[T] = object
    kind: Kind
    mark: bool
    members: seq[T]

  Reader*[T] = object
    ## Holds state for stream readers. This includes a stack
    ## of open frames, the atom header & payloads, as well
    ## as the last whole value read
    open: seq[OpenFrame[T]]
    head: array[6, byte]
    headLen: int
    payload: string
    size: int
    value*: T

func initReader*[T](cap = MaxDepth): Reader[T] =
  Reader[T](open: newSeqOfCap[OpenFrame[T]](cap))

func starved*[T](r: Reader[T]): bool =
  ## whether the bytes ran out inside a value rather than between two
  r.open.len > 0 or r.headLen > 0

proc readAtom[T: Readable](s: Stream, r: var Reader[T], val: var T, n: var int): bool =
  ## the atom headed by r.head[0], or false when the bytes run out first
  mixin atom
  template fill(upTo: int) =
    if r.headLen < upTo:
      r.headLen += s.readData(addr r.head[r.headLen], upTo - r.headLen)
      if r.headLen < upTo: return false
  let (kind, mark, inlineLen) = headerData(r.head[0])
  var length = inlineLen
  if inlineLen == 7:
    fill 2
    length = r.head[1].int
    guard length >= 7, "non minimal medium length"
    if length == 255:
      fill 6
      length = 0
      for i in 2..5:
        length = (length shl 8) or r.head[i].int
      guard length >= 255, "non minimal large length"
  n = r.headLen + length
  guard r.size + n <= MaxValueBytes, "value larger than MaxValueBytes"
  let have = r.payload.len
  if have < length:
    r.payload.setLen length
    let got = s.readData(addr r.payload[have], length - have)
    r.payload.setLen have + got
    if have + got < length: return false
  val = T.atom(move r.payload, kind, mark)
  true

proc readStream*[T: Readable](s: Stream, r: var Reader[T]): bool =
  ## reads on from where r stopped, answering true once a value was read
  ## whole, storing it in r.value. Otherwise this returns false if it
  ## is starved and can wait to resume without reading anything twice.
  ## 
  ## If invalid CE is read r is poisoned and won't produce anything
  ## useful in the future
  mixin null, frame
  while true:
    if r.headLen == 0:
      if s.readData(addr r.head[0], 1) != 1: return false
      r.headLen = 1
    var
      v: T
      n = 1
    case partialKind(r.head[0])
    of pvOpenFrame:
      guard r.open.len < MaxDepth, "frames nested deeper than MaxDepth"
      let (kind, mark, _) = headerData(r.head[0])
      r.open.add OpenFrame[T](kind: kind, mark: mark, members: newSeqOfCap[T](10))
      r.headLen = 0
      r.size += 1
      continue
    of pvCloseFrame:
      guard r.open.len > 0, "end at top level"
      var f = r.open.pop
      v = T.frame(move f.members, f.kind, f.mark)
    of pvNil:
      v = T.null(headerData(r.head[0]).mark)
    of pvAtom:
      if not s.readAtom(r, v, n): return false
    r.headLen = 0
    r.size += n
    guard r.size <= MaxValueBytes, "value larger than MaxValueBytes"
    if r.open.len == 0:
      r.size = 0
      r.value = move v
      return true
    r.open[^1].members.add move v

# ================
# Stream Writing
# ================

proc writeHeader(stream: Stream, kind: Kind, mark: bool, len: int) =
  let
    k: byte = kind.tag
    m: byte = if mark: MarkBit else: 0
    l: byte = byte min(len, 7)
    h: byte = ((k shl 4) or m or l)
  stream.write h
  if len in 7..254:
    stream.write byte(len)
  elif len >= 255:
    stream.write 0xFF'u8
    for shift in [24, 16, 8, 0]:
      stream.write byte((len shr shift) and 0xFF)

proc writeAtom(stream: Stream, kind: Kind, mark: bool, payload: string) =
  guard payload.len <= MaxPayload.int, "payload too large"
  stream.writeHeader(kind, mark, payload.len)
  stream.write payload

proc writeStream*[T: Walkable](stream: Stream, val: T) =
  guard val.valid, "writing invalid value"
  case val.kind
  of bNil:
    stream.writeHeader(bNil, val.mark, 0)
  of bNum:
    stream.writeAtom(val.kind, val.mark, val.digits)
  of bText..bBytes:
    stream.writeAtom(val.kind, val.mark, val.payload)
  else:
    stream.writeHeader(val.kind, val.mark, 0)
    for child in val.children:
      stream.writeStream(child)
    stream.write(EndByte)

# ================
# Walkable Derivations
# ================

func basslineCmp*[T: Walkable](a, b: T): int =
  ## Implements a generic comparison that matches
  ## CE comparison / memcmp for any `Walkable` type.
  ## See `makeCmp` which will define the
  ## comparison procs (`==`, `<`, `<=`) for a type
  ## in terms of this.
  template `??`(body) =
    result = body
    if result != 0:
      return
  ??cmp(a.kind, b.kind)
  ??cmp(a.mark, b.mark)
  case a.kind
  of bNil:
    discard
  of bNum:
    when compiles(cmpNums(a, b)):
      ??cmpNums(a, b)
    else:
      ??cmpShortlex(a.digits, b.digits)
  of bText .. bBytes:
    ??cmpShortlex(a.payload, b.payload)
  of bList, bRec, bSet, bDict:
    for i in 0 ..< min(a.len, b.len):
      ??cmp(a.getChild(i), b.getChild(i))
    ??cmp(b.len, a.len)

template makeCmp*(T) =
  ## Defines comparison procs for a type in
  ## terms of `basslineCmp` which implements
  ## a comparison that's equivalent to memcmp
  ## over CE bytes.
  ## 
  ## If the type isn't storing numbers as
  ## a string / bytes, you should implement
  ## `cmpNums(a, b: T)`: int which will allow
  ## the type to avoid using shortlex `digits`
  ## for the comparison. `BNum` is a good type
  ## for this.
  func cmp*(a, b: T): int =
    basslineCmp(a, b)
  func `==`*(a, b: T): bool =
    cmp(a, b) == 0
  func `<`*(a, b: T): bool =
    cmp(a, b) < 0
  func `<=`*(a, b: T): bool =
    cmp(a, b) <= 0

proc atomSize[T: Walkable](self: T): int =
  case self.kind
  of bNum: self.digits.len
  of bText, bSym, bBytes: self.payload.len
  else: 0

proc encodedSize*[T: Walkable](self: T, total: var int) =
  case self.kind
  of bNil: total += 1
  of bNum..bBytes:
    let len = self.atomSize
    case len:
    of 0..6:
      total += 1 + len
    of 7..254:
      total += 2 + len
    else:
      total += 6 + len
  else:
    total += 2
    for each in self.children:
      each.encodedSize(total)

proc encodedSize*[T: Walkable](self: T): int =
  self.encodedSize(result)

proc ce*[T: Walkable](self: T): string =
  let s = newStringStream(newStringUninit(self.encodedSize))
  s.writeStream(self)
  move s.data