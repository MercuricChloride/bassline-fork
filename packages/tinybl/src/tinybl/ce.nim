from std/bitops import countTrailingZeroBits
import std/[options, streams]
export options

when not defined(js):
  from std/endians import littleEndian64

const
  MaxDepth* {.intdefine.} = 64
  MaxValueBytes* {.intdefine.} = 100 * 1024 * 1024
    ## default cap on what a decoder buffer for one value: a scalar
    ## payload this large, or an unclosed frame that reaches this many
    ## bytes, is refused rather than held. CE tops out at ~4.3GB; a
    ## receiver draws the line lower at its boundary. Per-decoder
    ## override via `newDecoder(maxValueBytes = …)`.
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

func cmpShortlex*(x, y: openArray[byte]): int =
  result = cmp(x.len, y.len)
  if result != 0: return
  result = cmpBytes(x, y)

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

  Walkable* = concept
    proc valid(self: Self): bool
    proc kind(self: Self): Kind
    proc mark(self: Self): bool
    proc digits(self: Self): string
    proc payload(self: Self): string
    iterator children(self: Self): Self

# ================
# Stream Reading
# ================

proc readAtom[T: Readable](self: Stream, val: var T): bool =
  mixin null, atom
  if self.atEnd: return
  let startPos = self.getPosition
  try:
    var
      headerByte: byte
      med: uint8
      large: array[4, uint8]
      length: int
    self.read(headerByte)
    let (kind, mark, inlineLen) = headerData(headerByte)
    length = inlineLen
    if inlineLen == 7:
      self.read(med)
      guard med >= 7, "non minimal medium length"
      length = med.int
    if length == 255:
      self.read(large)
      length = 0
      for i in 0..3:
        length = (length shl 8) or int(large[i])
      guard length >= 255, "non minimal large length"
    if length > 0:
      var bytes = newStringOfCap(length)
      let bytesRead = self.readData(addr(bytes[0]), length)
      guard bytesRead == bytes.len, "stream truncated"
      val = T.atom(move bytes, kind, mark)
    else:
      val = T.atom("", kind, mark)
    true
  except:
    self.setPosition(startPos)
    raise

proc readStream*[T: Readable](self: Stream, val: var T): bool =
  mixin null, frame
  if self.atEnd: return
  let pos = self.getPosition
  var headerByte: byte
  self.peek(headerByte)
  case partialKind(headerByte)
  of pvNil:
    let (_, mark, _) = headerData(headerByte)
    self.setPosition(pos + 1)
    val = T.null(mark)
    return true
  of pvCloseFrame:
    self.setPosition(pos + 1)
    return
  of pvOpenFrame:
    let (kind, mark, _) = headerData(headerByte)
    self.setPosition(pos + 1)
    var children = newSeqOfCap[T](10)
    var child: T
    while self.readStream(child):
      children.add move(child)
    val = T.frame(move children, kind, mark)
    return true
  of pvAtom:
    return self.readAtom(val)

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