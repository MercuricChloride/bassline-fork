from std/bitops import countTrailingZeroBits
from std/endians import littleEndian64

const
  MaxDepth* {.intdefine.} = 64
  MaxPayload* = uint32.high
  EndByte*: byte = 0xA0
  MarkBit*: byte = 0x08

type CodecError* = object of CatchableError

template guard*(cond: bool, msg: string) =
  if not cond:
    raise newException(CodecError, msg)

template ensure*(cond: bool) =
  result = cond
  if not result: return

func cmpBytes*(a, b: openArray[byte]): int =
  let n = min(a.len, b.len)
  if n > 0:
    let r = cmpMem(addr a[0], addr b[0], n)
    if r != 0: return r
  a.len - b.len

func isValidInt*(bytes: openArray[byte]): bool =
  ensure bytes.len > 0
  let start = if bytes[0] == '-'.byte: 1 else: 0
  ensure bytes.len > start # bare "-" refused
  if bytes[start] == '0'.byte:
    ensure start == 0 # "-0" refused
    ensure bytes.len == 1 # leading zeros refused
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

type
  Kind* = enum
    bNil,
    bNum, bText, bSym, bBytes,
    bList, bRec, bDict, bSet
  HeaderData* = tuple
    kind: Kind
    mark: bool
    inlineLen: int

  PartialValueKind* = enum
    pvNil, pvAtom, pvOpenFrame, pvCloseFrame

  PartialValue* = object
    offset*: int
    case kind*: PartialValueKind
    of pvAtom:
      payloadLen*: uint32
    else: discard

func tag*(kind: Kind): byte =
  byte(kind.ord + 1)

func skipLen*(payloadLen: uint32): int =
  case payloadLen
  of 0..6: 1
  of 7..254: 2
  else: 6

func headerData*(b: byte): HeaderData =
  let
    tag = int(b shr 4)
    mark = (b and MarkBit) != 0
    len = int(b and 7)
  guard tag in 1..9, ("invalid tag: " & $tag)
  (Kind(tag - 1), mark, len)

func partialKind*(b: byte): PartialValueKind =
  if b == EndByte:
    return pvCloseFrame
  let h = headerData(b)
  case h.kind
  of bNum..bBytes: 
    pvAtom
  of bNil:
    pvNil
  of bList..bSet:
    pvOpenFrame

type
  Buffer* = ref object
   pos*: Natural
   data*: seq[byte]
  BufferStarvedError* = object of CatchableError

func newBuffer*(): Buffer = 
  Buffer()

func newBuffer*(data: sink seq[byte]): Buffer =
  Buffer(data: data)

func len*(self: Buffer): Natural =
  self.data.len

proc `[]`*(self: Buffer, i: Natural): byte =
  self.data[i]

iterator partialValues*(self: var Buffer): PartialValue =
  while self.data.len > self.pos:
    let
      b = self.data[self.pos]
      pk = b.partialKind
    case pk
    of pvNil, pvOpenFrame, pvCloseFrame:
      yield PartialValue(kind: pk, offset: self.pos)
      self.pos += 1
    of pvAtom:
      var
        len = b.headerData.inlineLen
      if len == 7:
        if not self.data.len > (self.pos + 1):
          raise newException(BufferStarvedError, "expected a length byte")
        len = int self.data[self.pos + 1]
        guard len >= 7: "non minimal u8 length"
        if len == 255:
          if not self.data.len > (self.pos + 5):
            raise newException(BufferStarvedError, "expected 4 length bytes")
          for i in 2 .. 5:
            len = (len shl 8) or int self.data[self.pos + i]
          guard len >= 255, "non minimal u32 length"
      let pv = PartialValue(kind: pvAtom, offset: self.pos, payloadLen: uint32(len))
      self.pos += pv.payloadLen.skipLen + len
      yield pv