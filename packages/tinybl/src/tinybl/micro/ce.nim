##[
This file implements everything required for a EXTRA minimal bassline
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
    ## The max frame depth a reader will handle for a single value before refusing
  MaxValueBytes* {.intdefine.} = 100 * 1024 * 1024
    ## The max byte len a reader will handle for a single value before refusing
  MaxAtomPayload* = uint32.high
    ## Max atom payload byte len as specified by the data model
  EndByte*: byte = 0xA0
  MarkBit*: byte = 0x08

type BasslineError* = object of ValueError

# ================
# Error utils
# ================

template refuseWith*(err) {.dirty.} =
  ## gives a module its own `refuse` & `guard` templates
  template refuse(msg: string) =
    raise newException(err, msg)

  template guard(cond: untyped, msg: string) {.used.} =
    if not (cond): refuse(msg)

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

func headerData*(b: byte): tuple[kind: Kind, mark: bool, inlineLen: int] {.inline.} =
  let
    tag = int(b shr 4)
    mark = (b and MarkBit) != 0
    len = int(b and 7)
  guard tag in 1..9, ("invalid tag: " & $tag)
  (Kind(tag - 1), mark, len)

type
  PartialValueKind* = enum
    pvNil, pvAtom, pvOpenFrame, pvCloseFrame

func partialKind*(b: byte): PartialValueKind {.inline.} =
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
  if bytes.len > 0:
    copyMem(beginStore(result, bytes.len), addr bytes[0], bytes.len)
    endStore(result)

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
  BuildAlg*[V] = concept
    proc null(self: Self, mark: bool): V
    proc atom(self: Self, s: sink string, k: Kind, m: bool): V
    proc frame(self: Self, s: sink seq[V], k: Kind, m: bool): V

  EncAlg* = concept e
    e.writeNull(bool)
    e.writeAtom(Kind, bool, sink string)
    e.writeOpen(Kind, bool)
    e.writeClose()

# ================
# Reading
# ================

type
  OpenFrame[T] = object
    kind: Kind
    mark: bool
    members: seq[T]

  Reader*[V;B] = object
    ## Holds state for reading CE in pieces. This includes a stack
    ## of open frames, the atom header & payloads, as well
    ## as the last whole value read
    open: seq[OpenFrame[V]]
    head: array[6, byte]
    headLen: int
    payload: string
    size: int
    frameCap: int
    builder*: B
    value*: V

const DefaultFrameCap* {.intdefine.} = 3
  ## Default size of seqs for frames
  ## 3 seems to be a good optimization

func initReader*[V; B: BuildAlg[V]](
    builder: B, cap = MaxDepth, frameCap = DefaultFrameCap
): Reader[V, B] =
  Reader[V, B](
    open: newSeqOfCap[OpenFrame[V]](cap), builder: builder, frameCap: frameCap
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
      copyMem(beginStore(dst, have + n, have), addr src[at], n)
      endStore(dst)

proc readAtom[V; B: BuildAlg[V]](
    r: var Reader[V,B], src: openArray[char], pos: var int, val: var V, n: var int
): bool =
  mixin atom
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
  val = r.builder.atom(move r.payload, kind, mark)
  when nimvm:
    # the VM's move copies, leaving the payload behind
    r.payload.setLen 0
  true

proc readCE*[T;B: BuildAlg[T]](
    r: var Reader[T,B], src: openArray[char], pos: var int): bool =
  mixin null, frame
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
      v = r.builder.frame(move f.members, f.kind, f.mark)
    of pvNil:
      v = r.builder.null(headerData(r.head[0]).mark)
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

iterator readEach*[T;B:BuildAlg[T]](r: var Reader[T,B], src: openArray[char]): T =
  ## every value src finishes r carrying on from where it stopped
  var pos = 0
  while r.readCE(src, pos):
    yield move r.value

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

proc writeNull*(dst: var string, mark: bool) =
  dst.writeHeader(bNil, mark, 0)

proc writeAtom*(dst: var string, kind: Kind, mark: bool, payload: sink string) =
  guard payload.len <= MaxAtomPayload.int, "payload too large"
  dst.writeHeader(kind, mark, payload.len)
  dst.add payload

proc writeOpen*(dst: var string, kind: Kind, mark: bool) =
  guard kind in bList..bSet, "tried to open a non frame"
  dst.writeHeader(kind, mark, 0)

proc writeClose*(dst: var string) =
  dst.add char(EndByte)