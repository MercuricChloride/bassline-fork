##[
This file implements everything required for a minimal bassline
implementation with a few additional bits of sugar for ergonomics.

We use the convention of strings for binary data, even though
a seq[byte] would be more semantically appropriate. However
the nim stdlib uses string for often for binary data so I just decided
to keep it as they had it to prevent casting / needless copying.

This may change in the future, but for now this is how it's done.
]##
from std/bitops import countTrailingZeroBits
import std/options
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

  template guard(cond: untyped, msg: string) {.used.} =
    if not (cond):
      refuse(msg)

refuseWith BasslineError

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

func toString*(bytes: openArray[byte]): string =
  ## bytes as the string tinybl holds a payload in
  result = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], addr bytes[0], bytes.len)

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

func isValidInt*(str: string): bool =
  if str.len == 0:
    return false
  let start = if str[0] == '-': 1 else: 0
  if str.len <= start:
     # bare "-" refused
    return false
  if str[start] == '0':
    if start != 0: return false
    if str.len != 1: return false
  for i in start ..< str.len:
    if str[i] notin {'0'..'9'}:
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

func isValidUtf8*(str: string): bool =
  str.toBytes.isValidUtf8

# ================
# Value Concepts
# ================

type
  Builder*[T] = concept
    ## Builder is a concept for whatever makes values of T
    ## from the parts a reader produces. Atoms from their
    ## payloads & frames from their members in order. A
    ## builder may hold state of its own, but for stateless
    ## builders, you can use ByType[T] which allows for
    ## construction from the typedesc[T] itself.
    proc buildNull(self: Self, mark: bool): T
    proc buildAtom(self: Self, bytes: sink string, kind: Kind, mark: bool): T
    proc buildFrame(self: Self, members: sink seq[T], kind: Kind, mark: bool): T

  ToString* = concept v
    $v is string

  Stringy* = string | ToString

  CheckedVal* = concept v, var mut
    v is Walkable
    v.valid is bool
    mut.validate

  Walkable* = concept v, type T
    ## Walkable is a concept for an object
    ## that supports traversal as though it
    ## were an encoded bassline value with
    ## correct ce structure
    ##
    ## payload & digits should return binary
    ## strings being the payload of an atom
    ##
    ## children are the constituents of frames
    ## and for dicts it is expected to alternate
    ## K V K V
    ## Same goes with getChild. foo.getChild(0) should
    ## return the first key in the dict, and getChild(1) its value
    type
      Num = typeof v.numVal
    v.kind is Kind
    v.mark is bool
    # atoms
    Num is string | ToString
    v.textVal is string
    v.symVal is string
    v.bytesVal is string
    # frames
    v.len is int
    v.getChild(int) is lent T

  ByType*[T] = object
    ## A builder for types that implement Builder[T] without
    ## state and dispatch on the typedesc[T] itself

proc numStr*(self: Walkable): string =
  self.expectKind(bNum)
  when self.numVal is string:
    self.numVal
  else:
    $(self.numVal)

proc buildNull*[T](self: ByType[T], mark: bool): T =
  mixin buildNull
  T.buildNull(mark)

proc buildAtom*[T](self: ByType[T], bytes: sink string, kind: Kind, mark: bool): T =
  mixin buildAtom
  T.buildAtom(bytes, kind, mark)

proc buildFrame*[T](self: ByType[T], members: sink seq[T], kind: Kind, mark: bool): T =
  mixin buildFrame
  T.buildFrame(members, kind, mark)

# ================
# Reading
# ================

type
  OpenFrame[T] = object
    kind: Kind
    mark: bool
    members: seq[T]

  Reader*[T,B] = object
    ## Holds state for reading CE in pieces. This includes a stack
    ## of open frames, the atom header & payloads, as well
    ## as the last whole value read
    open: seq[OpenFrame[T]]
    head: array[6, byte]
    headLen: int
    payload: string
    size: int
    frameCap: int
    builder*: B
    value*: T

  TypeReader*[T] = Reader[T, ByType[T]]
    ## a reader for a type that builds itself

const DefaultFrameCap* {.intdefine.} = 3

func initReader*[T; B: Builder[T]](
    builder: B, cap = MaxDepth, frameCap = DefaultFrameCap
): Reader[T, B] =
  Reader[T, B](
    open: newSeqOfCap[OpenFrame[T]](cap), builder: builder, frameCap: frameCap
  )

func starved*[T; B](r: Reader[T, B]): bool =
  ## whether the bytes ran out inside a value rather than between two
  r.open.len > 0 or r.headLen > 0

proc take(dst: var string, src: openArray[char], at, n: int) =
  ## appends the n bytes of src from at
  when nimvm:
    for i in at ..< at + n:
      dst.add src[i]
  else:
    if n > 0:
      let have = dst.len
      dst.setLen have + n
      copyMem(addr dst[have], addr src[at], n)

proc readAtom[T; B: Builder[T]](
    r: var Reader[T,B], src: openArray[char], pos: var int, val: var T, n: var int
): bool =
  ## the atom headed by r.head[0], or false when src runs out first
  mixin buildAtom
  template fill(upTo: int) =
    while r.headLen < upTo and pos < src.len:
      r.head[r.headLen] = byte(src[pos])
      inc r.headLen
      inc pos
    if r.headLen < upTo:
      return false

  let (kind, mark, inlineLen) = headerData(r.head[0])
  var length = inlineLen
  if inlineLen == 7:
    fill 2
    length = r.head[1].int
    guard length >= 7, "non minimal medium length"
    if length == 255:
      fill 6
      length = 0
      for i in 2 .. 5:
        length = (length shl 8) or r.head[i].int
      guard length >= 255, "non minimal large length"
  n = r.headLen + length
  guard r.size + n <= MaxValueBytes, "value larger than MaxValueBytes"
  let
    have = r.payload.len
    got = min(length - have, src.len - pos)
  r.payload.take(src, pos, got)
  pos += got
  if have + got < length:
    return false
  val = r.builder.buildAtom(move r.payload, kind, mark)
  when nimvm:
    # the VM's move copies, leaving the payload behind
    r.payload.setLen 0
  true

proc readCE*[T;B: Builder[T]](
    r: var Reader[T,B], src: openArray[char], pos: var int): bool =
  ## reads src from pos on, carrying on from where r stopped, and answers
  ## true once a value was read whole, storing it in r.value, with pos
  ## just past it. Otherwise src ran out, all of it taken from pos on,
  ## and r can resume on the bytes that follow without reading anything
  ## twice.
  ##
  ## If invalid CE is read r is poisoned and won't produce anything
  ## useful in the future
  mixin buildNull, buildFrame
  while true:
    if r.headLen == 0:
      if pos >= src.len:
        return false
      r.head[0] = byte(src[pos])
      inc pos
      r.headLen = 1
    var
      v: T
      n = 1
    case partialKind(r.head[0])
    of pvOpenFrame:
      guard r.open.len < MaxDepth, "frames nested deeper than MaxDepth"
      let
        (kind, mark, _) = headerData(r.head[0])
        room = if r.frameCap > 0: r.frameCap else: DefaultFrameCap
      r.open.add OpenFrame[T](kind: kind, mark: mark, members: newSeqOfCap[T](room))
      r.headLen = 0
      r.size += 1
      continue
    of pvCloseFrame:
      guard r.open.len > 0, "end at top level"
      var f = r.open.pop
      v = r.builder.buildFrame(move f.members, f.kind, f.mark)
    of pvNil:
      v = r.builder.buildNull(headerData(r.head[0]).mark)
    of pvAtom:
      if not r.readAtom(src, pos, v, n):
        return false
    r.headLen = 0
    r.size += n
    guard r.size <= MaxValueBytes, "value larger than MaxValueBytes"
    if r.open.len == 0:
      r.size = 0
      r.value = move v
      return true
    r.open[^1].members.add move v

iterator readEach*[T;B: Builder[T]](r: var Reader[T,B], src: openArray[char]): T =
  ## every value src finishes, r carrying on from where it stopped
  var pos = 0
  while r.readCE(src, pos):
    yield r.value

# ================
# Writing
# ================

proc writeHeader(dst: var string, kind: Kind, mark: bool, len: int) =
  let
    k: byte = kind.tag
    m: byte = if mark: MarkBit else: 0
    l: byte = byte min(len, 7)
    h: byte = ((k shl 4) or m or l)
  dst.add char(h)
  if len in 7..254:
    dst.add char(len)
  elif len >= 255:
    dst.add '\xFF'
    for shift in [24, 16, 8, 0]:
      dst.add char((len shr shift) and 0xFF)

proc writeAtom(dst: var string, kind: Kind, mark: bool, payload: string) =
  guard payload.len <= MaxPayload.int, "payload too large"
  dst.writeHeader(kind, mark, payload.len)
  dst.add payload

proc writeCE*(dst: var string, val: Walkable) =
  ## appends val's CE to dst
  when val is CheckedVal:
    guard val.valid, "writing invalid value"
  template emitAtom(s) =
    dst.writeAtom(val.kind, val.mark, s)
  case val.kind
  of bNil:
    dst.writeHeader(bNil, val.mark, 0)
  of bNum:
    emitAtom(val.numStr)
  of bText:
    emitAtom(val.textVal)
  of bSym:
    emitAtom(val.symVal)
  of bBytes:
    emitAtom(val.bytesVal)
  else:
    dst.writeHeader(val.kind, val.mark, 0)
    for i in 0..<val.len:
      dst.writeCE(val.getChild(i))
    dst.add char(EndByte)

# ================
# Walkable Derivations
# ================

type
  SameContents = concept a, b
    sameContents(a, b) is bool
  CmpNums = concept a, b
    cmpNums(a, b) is int

func basslineCmp*(a, b: Walkable): int =
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
  when a is SameContents:
    if sameContents(a, b):
      return 0
  case a.kind
  of bNil:
    discard
  of bNum:
    when a.Num is CmpNums:
      ??cmpNums(a.numVal, b.numVal)
    elif a.Num is string:
      ??cmpShortlex(a.numVal, b.numVal)
    else:
      ??cmpShortlex($(a.numVal), $(b.numVal))
  of bText:
    ??cmpShortLex(a.textVal, b.textVal)
  of bSym:
    ??cmpShortLex(a.symVal, b.symVal)
  of bBytes:
    ??cmpShortlex(a.bytesVal, b.bytesVal)
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
  ##
  ## A type that can tell cheaply when two values
  ## hold the same contents, whatever their marks,
  ## can implement `sameContents(a, b: T): bool`, and the
  ## comparison skips the walk when it returns true.
  ##
  ## `cmp` says what it raises because it calls itself through
  ## `basslineCmp`, and Nim takes a call it is still inferring
  ## to raise anything.
  func cmp*(a, b: T): int {.raises: [BasslineError].} =
    basslineCmp(a, b)
  func `==`*(a, b: T): bool =
    cmp(a, b) == 0
  func `<`*(a, b: T): bool =
    cmp(a, b) < 0
  func `<=`*(a, b: T): bool =
    cmp(a, b) <= 0

proc atomSize(self: Walkable): int =
  case self.kind
  of bNum: self.numStr.len
  of bText: self.textVal.len
  of bSym: self.symVal.len
  of bBytes: self.bytesVal.len
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
  result = newStringOfCap(self.encodedSize)
  result.writeCE(self)

iterator children*[T: Walkable](self: T): T =
  if self.kind in {bList..bSet}:
    for i in 0..<self.len:
      yield self.getChild(i)

iterator walk*[T: Walkable](self: T): T {.closure.} =
  mixin children
  yield self
  for child in self.children:
    for each in walk(child):
      yield each

const
  anyMark* = none(bool)
  unmarked* = some(false)
  marked* = some(true)

  slotted* = {bList, bRec}
  keyed* = {bDict, bSet}
  textual* = {bText, bSym}
  numeric* = {bNum}

func isKind*[T](a: T, k: set[Kind], mark = anyMark): bool =
  a.kind in k and (
    if mark.isSome: a.mark == mark.get else: true
  )

func isKind*[T](a: T, k: Kind, mark = anyMark): bool =
  a.isKind({k}, mark)

func expectKind*[T](a: T, k: set[Kind], mark = anyMark) =
  guard a.isKind(k, mark),
    "expected value of kind: " & $k &
      (if mark.isNone: "" elif mark.get: ", marked" else: ", unmarked")

func expectKind*[T](a: T, k: Kind, mark = anyMark) =
  expectKind(a, {k}, mark)

func expectAllKind*[T](a: openArray[T], k: set[Kind], mark = anyMark) =
  for each in a:
    each.expectKind(k, mark)

func expectAllKind*[T](a: openArray[T], k: Kind, mark = anyMark) =
  for each in a:
    each.expectKind(k, mark)

template expectSlot*(v: untyped, i: int) =
  guard i >= 0 and i < v.slotLen, "no slot at " & $i