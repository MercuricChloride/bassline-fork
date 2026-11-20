from std/bitops import countTrailingZeroBits
when not defined(js):
  from std/endians import littleEndian64
import std/options
export options

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
  Frame* = ref object of RootObj
  Entry*[K,V] = tuple[key:K, val:V]
  Pair*[T] = Entry[T,T]

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
# String & bytes support
# ================

func toString*(a: openArray[byte]): string =
  result = newString(a.len)
  when defined(js):
    for i, b in a: result[i] = char b
  else:
    when nimvm:
      for i, b in a: result[i] = char b
    else:
      if a.len > 0:
        copyMem(addr result[0], addr a[0], a.len)

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