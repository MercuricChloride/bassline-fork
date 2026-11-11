##[
This file implements everything required for a EXTRA minimal bassline
implementation with a few additional bits of sugar for ergonomics.

We use the convention of strings for binary data, even though
a seq[byte] would be more semantically appropriate. However
the nim stdlib uses string for often for binary data so I just decided
to keep it as they had it to prevent casting / needless copying.

This may change in the future, but for now this is how it's done.

The file reads top to bottom: limits, kinds, bytes, numbers, the sorted
containers, values, constructors, reification, reading and writing.
Everything under Sugar at the end is convenience over what comes before
it, and nothing before it leans on it.
]##
from std/bitops import countTrailingZeroBits
from std/strutils import parseBiggestInt
from std/algorithm import sort, lowerBound
import std/[options, hashes]
import bigints
export options

when not defined(js):
  from std/endians import littleEndian64

# ================
# Limits & refusals
# ================

const
  MaxDepth* {.intdefine.} = 64
    ## The max frame depth a reader will handle for a single value before refusing
  MaxValueBytes* {.intdefine.} = 100 * 1024 * 1024
    ## The max byte len a reader will handle for a single value before refusing
  MaxAtomPayload* = uint32.high
    ## Max atom payload byte len as specified by the data model
  DefaultFrameCap* {.intdefine.} = 3
    ## Default size of seqs for frames
    ## 3 seems to be a good size
  EndByte*: byte = 0xA0
  MarkBit*: byte = 0x08

type BasslineError* = object of ValueError

template refuseWith*(err) {.dirty.} =
  ## gives a module its own `refuse` & `guard` templates
  template refuse(msg: string) =
    raise newException(err, msg)

  template guard(cond: untyped, msg: string) {.used.} =
    if not (cond): refuse(msg)

refuseWith BasslineError

# ================
# Kinds & headers
# ================

type
  Kind* = enum
    bNil,
    bNum, bText, bSym, bBytes,
    bList, bRec, bDict, bSet

  PartialValueKind* = enum
    pvNil, pvAtom, pvOpenFrame, pvCloseFrame

func tag*(kind: Kind): byte =
  byte(kind.ord + 1)

func headerData*(b: byte): tuple[kind: Kind, mark: bool, inlineLen: int] {.inline.} =
  let
    tag = int(b shr 4)
    mark = (b and MarkBit) != 0
    len = int(b and 7)
  guard tag in 1..9, ("invalid tag: " & $tag)
  (Kind(tag - 1), mark, len)

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
# Bytes
# ================

template toBytes*(a: string): openArray[byte] =
  a.toOpenArrayByte(0, a.high)

func toString*(bytes: openArray[byte]): string =
  ## bytes as the string tinybl holds a payload in
  if bytes.len > 0:
    copyMem(beginStore(result, bytes.len), addr bytes[0], bytes.len)
    endStore(result)

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
# Atom laws
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
# Numbers
# ================

type
  BNum* = object
    case
    of Small:
      small: int
    of Big:
      big: BigInt

func initNum*(n: SomeInteger): BNum =
  when n is uint64 or n is uint:
    if n > uint64(high(int)):
      return Big(big: initBigInt(uint64(n)))
  Small(small: n.int)

func initNum*(n: BigInt): BNum =
  # a number has one holding: Big only when it is past an int
  let fits = toInt[int](n)
  if fits.isSome: Small(small: fits.get)
  else: Big(big: n)

func initNum*(s: string): BNum =
  ## s is a canonical spelling; past int64 it is held as it is spelled
  guard isValidInt(s), "not a canonical number: " & s
  try:
    Small(small: parseBiggestInt(s))
  except ValueError:
    try:
      Big(big: initBigInt(s, 10))
    except ValueError:
      refuse("not a number: " & s)

func isInt*(n: BNum): bool =
  case n
  of Small: true
  else: false

func isBig*(n: BNum): bool =
  not n.isInt

func asInt*(n: BNum): int =
  case n
  of Small(x): x
  else: refuse "num is wide, not an int"

func asBig*(n: BNum): BigInt =
  case n
  of Big(x): x
  of Small(x): initBigInt(x)

func `$`*(n: BNum): string =
  case n
  of Big(x): $x
  of Small(x): $x

func hash*(n: BNum): Hash =
  case n
  of Big(x): hash(x)
  of Small(x): hash(x)

func magnitude*(x: int): uint64 =
  ## |x| without the abs(int.low) overflow
  if x < 0:
    uint64(-(x + 1)) + 1
  else:
    uint64(x)

func spellingLen(x: int): int =
  result = if x < 0: 2 else: 1
  var m = magnitude x
  while m >= 10:
    inc result
    m = m div 10

func cmpInts*(x, y: int): int =
  ## ascii shortlex over the decimal strings without making them strings
  result = cmp(spellingLen(x), spellingLen(y))
  if result != 0:
    return
  let nx = x < 0
  let ny = y < 0
  if nx != ny:
    return if nx: -1 else: 1
  result = cmp(magnitude(x), magnitude(y))

func cmpNums*(x, y: BNum): int =
  if x.isInt and y.isInt:
    cmpInts(x.asInt, y.asInt)
  else:
    cmpShortlex($x, $y)

# ================
# Sorted table
# ================

type
  SortedEntry*[K, V] = object
    key*: K
    val*: V

  SortedTable*[K, V] = object
    entries*: seq[SortedEntry[K, V]]

  SortedSet*[T] {.byref.} = object
    data*: seq[T]

func cmpKeys*[K, V](a, b: SortedEntry[K, V]): int =
  mixin cmp
  cmp(a.key, b.key)

func cmpKeys*[K, V](a: SortedEntry[K, V], b: K): int =
  mixin cmp
  cmp(a.key, b)

func toSortedTable*[K, V](
    entries: sink seq[SortedEntry[K, V]], sorted = false
): SortedTable[K, V] =
  mixin cmp
  if sorted:
    return SortedTable[K, V](entries: entries)
  # sorted as pairs, by a comparison that captures nothing, which the VM
  # can compile when this is instantiated for compile time too
  entries.sort(cmpKeys)
  SortedTable[K, V](entries: entries)

func fromRavel*[T](ravel: sink seq[T], sorted = false): SortedTable[T, T] =
  guard ravel.len mod 2 == 0, "ravel len must be even"
  var entries = newSeqOfCap[SortedEntry[T, T]](ravel.len div 2)
  for i in countup(1, ravel.high, 2):
    entries.add SortedEntry[T, T](key: move ravel[i - 1], val: move ravel[i])
  toSortedTable(entries, sorted)

func len*[K, V](self: SortedTable[K, V]): Natural =
  self.entries.len

func getRavel*[T](self: SortedTable[T,T], i: int): lent T =
  if i mod 2 == 0:
    return self.entries[i div 2].key
  else:
    return self.entries[i div 2].val

func strictlyAscending*[K, V](self: SortedTable[K, V]): bool =
  mixin cmp
  for i in 1 ..< self.entries.len:
    if cmp(self.entries[i - 1].key, self.entries[i].key) >= 0:
      return false
  true

func lowerIdx[K, V](self: SortedTable[K, V], key: K): int =
  ## the first index whose key is not below key
  mixin cmp
  self.entries.lowerBound(key, cmpKeys)

func indexOf*[K, V](self: SortedTable[K, V], key: K): int =
  ## key's index, or -1 when it has none
  mixin cmp
  let i = self.lowerIdx(key)
  if i < self.len and cmpKeys(self.entries[i], key) == 0: i else: -1

func put*[K, V](
    self: var SortedTable[K, V],
    key: sink K, val: sink V,
    force = true) =
  mixin cmp
  let i = self.lowerIdx(key)
  if i < self.entries.len and cmpKeys(self.entries[i], key) == 0:
    if not force:
      refuse "key already exists"
    self.entries[i].val = val
  else:
    self.entries.insert(SortedEntry[K,V](key: key, val: val), i)

func insert*[K,V](self: var SortedTable[K,V], key: sink K, val: sink V) =
  ## like put, but throws is this will replace an existing key
  self.put(key, val, force = false)

func normalize*[K,V](self: var SortedTable[K,V]) =
  var entries = move self.entries
  self.entries.setLen 0
  for e in entries.mitems:
    self.insert(move e.key, move e.val)

# ================
# Sorted set
# ================

func toSortedSet*[T](self: sink seq[T], sorted = false): SortedSet[T] =
  mixin cmp
  result.data = self
  if not sorted:
    result.data.sort(cmp)

func len*[T](self: SortedSet[T]): Natural =
  self.data.len

func strictlyAscending*[T](self: SortedSet[T]): bool =
  mixin cmp
  for i in 1 ..< self.data.len:
    if cmp(self.data[i - 1], self.data[i]) >= 0:
      return false
  true

func lowerIdx[T](self: SortedSet[T], val: T): int =
  ## the first index whose member is not below val
  mixin cmp
  self.data.lowerBound(val, cmp)

func indexOf*[T](self: SortedSet[T], val: T): int =
  ## val's index, or -1 when it isn't a member
  mixin cmp
  let i = self.lowerIdx(val)
  if i < self.data.len and cmp(self.data[i], val) == 0: i else: -1

func incl*[T](self: var SortedSet[T], val: sink T) =
  mixin cmp
  let i = self.lowerIdx(val)
  if i < self.data.len and cmp(self.data[i], val) == 0:
    return
  self.data.insert(val, i)

func normalize*[T](self: var SortedSet[T]) =
  var els = move self.data
  self.data.setLen 0
  for e in els.mitems:
    self.incl move e

# ================
# Values
# ================

type
  Live* = ref object of RootObj

  Node* = object
    case
    of Plain:
      value*: Value
    of Bound:
      live*: Live

  Value* = object
    mark*: bool
    case kind*: Kind
    of bNil: discard
    of bNum:
      vnum*: BNum
    of bText, bSym, bBytes:
      vstr*: string
    of bList, bRec:
      vseq*: seq[Node]
    of bDict:
      vdict*: SortedTable[Node, Node]
    of bSet:
      vset*: SortedSet[Node]

func toNode*(self: sink Value): Node {.inline.} =
  Plain(value: self)

func toNode*(self: Live): Node =
  Bound(live: self)

method reify*(self: Live): Value {.base, sideEffect, raises: [BasslineError].} =
  refuse "reify must be implemented!"

# ================
# Doors
# ================

func isBound*(self: Node): bool =
  case self
  of Bound: true
  else: false

func isPlain*(self: Node): bool =
  not self.isBound

func asLive*(self: Node): Live =
  case self
  of Bound(v): v
  else: refuse("not live")

func asValue*(self: Node): lent Value =
  case self
  of Plain(n):
    return n
  else: refuse("not data")

func asValue*(self: var Node): var Value =
  case self
  of Plain(n):
    return n
  else: refuse "not data"

proc reify*(self: sink Node): Value =
  case self
  of Plain(n): n
  of Bound(l): l.reify

# ================
# Members
# ================

func isFrame*(self: Value): bool =
  self.kind in {bList..bSet}

func len*(a: Value): int =
  case a.kind
  of bList, bRec:
    a.vseq.len
  of bDict:
    a.vdict.len * 2
  of bSet:
    a.vset.len
  else: 0

func member*(a: Value, i: int): lent Node =
  case a.kind
  of bList, bRec:
    return a.vseq[i]
  of bDict:
    return a.vdict.getRavel(i)
  of bSet:
    return a.vset.data[i]
  else: refuse("not a frame")

iterator members*(a: Value): lent Node =
  # by index: looping over the members through a binding copies them whole
  case a.kind
  of bList, bRec:
    for i in 0 ..< a.vseq.len:
      yield a.vseq[i]
  of bDict:
    for i in 0 ..< a.vdict.entries.len:
      yield a.vdict.entries[i].key
      yield a.vdict.entries[i].val
  of bSet:
    for i in 0 ..< a.vset.data.len:
      yield a.vset.data[i]
  else: discard

# ================
# Order & hash
# ================

func cmp*(a, b: Live): int =
  cmp(cast[int](a), cast[int](b))

func cmp*(a, b: Node): int

func cmp*(a, b: Value): int =
  template `??`(x,y) =
    let r = cmp(x,y)
    if r != 0: return r

  a.kind ?? b.kind
  a.mark ?? b.mark

  case a.kind
  of bNil: 0
  of bNum:
    cmpNums(a.vnum, b.vnum)
  of bText, bSym, bBytes:
    cmpShortlex(a.vstr, b.vstr)
  of bList,bRec,bDict,bSet:
    for i in 0 ..< min(a.len, b.len):
      a.member(i) ?? b.member(i)
    cmp(b.len, a.len)

func cmp*(a, b: Node): int =
  case a
  of Bound(x):
    case b
    of Plain: 1
    of Bound(y): cmp(x, y)
  of Plain(x):
    case b
    of Bound: -1
    of Plain(y): cmp(x, y)

template ordered(T: typedesc) =
  func `==`*(a, b: T): bool =
    cmp(a, b) == 0

  func `<`*(a, b: T): bool =
    cmp(a, b) < 0

  func `<=`*(a, b: T): bool =
    cmp(a, b) <= 0

ordered Live
ordered Value
ordered Node

func hash*(self: Live): Hash =
  hash cast[pointer](self)

func hash*(self: Node): Hash

func hash*(self: Value): Hash =
  var h = self.kind.hash !& self.mark.hash
  case self.kind
  of bNil: discard
  of bNum:
    h = h !& self.vnum.hash
  of bText, bSym, bBytes:
    h = h !& self.vstr.hash
  else:
    for each in self.members:
      h = h !& each.hash
  !$h

func hash*(self: Node): Hash =
  if self.isBound: self.asLive.hash
  else: self.asValue.hash

# ================
# Constructors
# ================

func null*(mark = false): Value {.inline.} =
  Value(kind: bNil, mark: mark)

func atom*(kind: Kind, payload: sink string, mark = false): Value {.inline.} =
  case kind
  of bNum:
    Value(kind: bNum, mark: mark, vnum: initNum(payload))
  of bText, bSym:
    guard isValidUtf8(payload), "invalid utf8 bytes"
    Value(kind: kind, mark: mark, vstr: payload)
  of bBytes:
    Value(kind: bBytes, mark: mark, vstr: payload)
  else:
    refuse "not an atom"

func build(kind: Kind, members: sink seq[Node], mark, inOrder: bool): Value =
  case kind
  of bList, bRec:
    guard kind == bList or members.len > 0, "record must have a head"
    Value(kind: kind, mark: mark, vseq: members)
  of bDict:
    guard members.len mod 2 == 0, "dict cannot have stranded keys"
    let dict = fromRavel(members, sorted = inOrder)
    guard dict.strictlyAscending,
      (if inOrder: "dict keys must be strictly ascending" else: "dict key repeated")
    Value(kind: bDict, mark: mark, vdict: dict)
  of bSet:
    let els = toSortedSet(members, sorted = inOrder)
    guard els.strictlyAscending,
      (if inOrder: "set elements must be strictly ascending" else: "set element repeated")
    Value(kind: bSet, mark: mark, vset: els)
  else:
    refuse "not a frame"

func canonicalFrame*(kind: Kind, members: sink seq[Node], mark = false): Value {.inline.} =
  build(kind, members, mark, inOrder = true)

func frame*(kind: Kind, members: sink seq[Node], mark = false): Value =
  build(kind, members, mark, inOrder = false)

# ================
# Reification
# ================

func isPure*(a: Node): bool

func isPure*(n: Value): bool =
  for each in n.members:
    if not each.isPure: return false
  true

func isPure*(a: Node): bool =
  a.isPlain and a.asValue.isPure

proc reifyIn(self: var Node): bool

proc reifyIn(self: var Value): bool =
  case self.kind
  of bList, bRec:
    for i in 0 ..< self.vseq.len:
      if self.vseq[i].reifyIn: result = true
  of bSet:
    for i in 0 ..< self.vset.data.len:
      if self.vset.data[i].reifyIn: result = true
    if result: self.vset.normalize
  of bDict:
    for i in 0 ..< self.vdict.entries.len:
      if self.vdict.entries[i].key.reifyIn: result = true
      if self.vdict.entries[i].val.reifyIn: result = true
    if result: self.vdict.normalize
  else: discard

proc reifyIn(self: var Node): bool =
  if self.isBound:
    self = self.asLive.reify.toNode
    discard self.asValue.reifyIn
    true
  else:
    self.asValue.reifyIn

proc reifyDeep*(self: sink Value): Value =
  discard self.reifyIn
  self

proc reifyDeep*(self: sink Node): Value =
  self.reify.reifyDeep

# ================
# Reading
# ================

type
  OpenFrame = object
    kind: Kind
    mark: bool
    members: seq[Node]

  Reader* = object
    ## Holds state for reading CE in pieces. This includes a stack
    ## of open frames, the atom header & payloads, as well
    ## as the last whole value read
    open: seq[OpenFrame]
    head: array[6, byte]
    headLen: int
    payload: string
    size: int
    frameCap: int
    value*: Value

func initReader*(cap = MaxDepth, frameCap = DefaultFrameCap): Reader =
  Reader(open: newSeqOfCap[OpenFrame](cap), frameCap: frameCap)

func starved*(r: Reader): bool =
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

proc readAtom(
    r: var Reader, src: openArray[char], pos: var int, val: var Value, n: var int
): bool =
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
  val = atom(kind, move r.payload, mark)
  when nimvm:
    # the VM's move copies, leaving the payload behind
    r.payload.setLen 0
  true

proc readCE*(r: var Reader, src: openArray[char], pos: var int): bool =
  while true:
    if r.headLen == 0:
      if pos >= src.len:
        return false
      r.head[0] = byte(src[pos])
      inc pos
      r.headLen = 1
    var
      v: Value
      n = 1
    case partialKind(r.head[0])
    of pvOpenFrame:
      guard r.open.len < MaxDepth, "frames nested deeper than MaxDepth"
      let
        (kind, mark, _) = headerData(r.head[0])
        room = if r.frameCap > 0: r.frameCap else: DefaultFrameCap
      r.open.add OpenFrame(kind: kind, mark: mark, members: newSeqOfCap[Node](room))
      r.headLen = 0
      r.size += 1
      continue
    of pvCloseFrame:
      guard r.open.len > 0, "end at top level"
      var f = r.open.pop
      v = canonicalFrame(f.kind, move f.members, f.mark)
    of pvNil:
      v = null(headerData(r.head[0]).mark)
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
    r.open[^1].members.add toNode(move v)

iterator readEach*(r: var Reader, src: openArray[char]): Value =
  ## every value src finishes r carrying on from where it stopped
  var pos = 0
  while r.readCE(src, pos):
    yield move r.value

proc readOne*(r: var Reader, src: openArray[char]): Value =
  for one in r.readEach(src):
    return one
  refuse("failed to read one")

# ================
# Writing
# ================

type
  Enc* = concept e
    e.writeNull(bool)
    e.writeAtom(Kind, bool, sink string)
    e.writeOpen(Kind, bool)
    e.writeClose()

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

proc writeReified(n: Value, enc: var Enc) =
  mixin writeNull, writeAtom, writeOpen, writeClose
  case n.kind
  of bNil:
    enc.writeNull(n.mark)
  of bNum:
    enc.writeAtom(n.kind, n.mark, $n.vnum)
  of bText, bSym, bBytes:
    enc.writeAtom(n.kind, n.mark, n.vstr)
  else:
    enc.writeOpen(n.kind, n.mark)
    for each in n.members:
      each.asValue.writeReified(enc)
    enc.writeClose

proc write*(self: Value, enc: var Enc) =
  if self.isPure: self.writeReified(enc)
  else: self.reifyDeep.writeReified(enc)

proc write*(self: Node, enc: var Enc) =
  if self.isPure: self.asValue.writeReified(enc)
  else: self.reifyDeep.writeReified(enc)

# ==================================================
# Sugar
#
# Convenience over the stuff above
# ==================================================

# ================
# Kind names
# ================

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
# Number sugar
# ================

converter toNum*(n: SomeInteger): BNum =
  initNum(n)

converter toNum*(n: BigInt): BNum =
  initNum(n)

template compare(op, T) =
  func op*(a, b: BNum): T =
    if a.isInt and b.isInt:
      op(a.asInt, b.asInt)
    else:
      op(a.asBig, b.asBig)

compare `cmp`, int
compare `<`, bool
compare `<=`, bool
compare `==`, bool

func addFits(a, b: int): bool =
  if b >= 0:
    a <= high(int) - b
  else:
    a >= low(int) - b

func subFits(a, b: int): bool =
  if b >= 0:
    a >= low(int) + b
  else:
    a <= high(int) + b

func mulFits(a, b: int): bool =
  if a == 0 or b == 0:
    return true
  let most =
    if (a < 0) != (b < 0):
      magnitude(low(int))
    else:
      magnitude(high(int))
  magnitude(a) <= most div magnitude(b)

func divFits(a, b: int): bool =
  b != 0 and (a != low(int) or b != -1)

func truncated(a, b: BigInt): tuple[q, r: BigInt] =
  ## divmod(a,b) with rounding toward zero to match
  ## div rounding semantics with nim ints.
  let zero = initBigInt(0)
  guard b != zero, "division by zero"
  result = divmod(a, b)
  if result.r != zero and (a < zero) != (b < zero):
    result.q += initBigInt(1)
    result.r -= b

func quot(a, b: BigInt): BigInt =
  truncated(a, b).q

func rem(a, b: BigInt): BigInt =
  truncated(a, b).r

template arith(op, fits, wideOp) =
  func op*(a, b: BNum): BNum =
    if a.isInt and b.isInt and fits(a.asInt, b.asInt):
      initNum(op(a.asInt, b.asInt))
    else:
      initNum(wideOp(a.asBig, b.asBig))

arith `+`, addFits, `+`
arith `-`, subFits, `-`
arith `*`, mulFits, `*`
arith `div`, divFits, quot
arith `mod`, divFits, rem

func inc*(n: var BNum, by = 1) =
  n = n + by

func dec*(n: var BNum, by = 1) =
  n = n - by

func pow*(x: BNum, power: Natural): BNum =
  x.asBig.pow(power)

func powmod*(x: BNum, power: int, modulus: Natural): BNum =
  x.asBig.powmod(power, modulus)

iterator `..`*(a, b: BNum): BNum =
  ## Counts from `a` up to `b` (inclusive).
  var res = a
  while res <= b:
    yield res
    inc res

iterator `..<`*(a, b: BNum): BNum =
  ## Counts from `a` up to `b` (exclusive).
  var res = a
  while res < b:
    yield res
    inc res

func abs*(n: BNum): BNum =
  case n
  of Big(x):
    initNum(x.abs)
  of Small(x):
    if x < 0: initNum(x.magnitude)
    else: n

func strLen*(n: BNum): int =
  ## how many characters $n would take up
  case n
  of Big(x):
    # NOTE: bigints does a fast estimation for the size of the string here
    # so I will replace this later
    len($x)
  of Small(x):
    spellingLen(x)

# ================
# Table sugar
# ================

func toSortedTable*[K, V](
    self: openArray[SortedEntry[K, V]], sorted = false
): SortedTable[K, V] =
  toSortedTable(@self, sorted)

func toRavel*[T](self: sink SortedTable[T, T]): seq[T] =
  var s = newSeqOfCap[T](self.entries.len * 2)
  for each in self.entries.mitems:
    s.add move(each.key)
    s.add move(each.val)
  s

func sort*[K,V](self: var SortedTable[K,V]) =
  self.entries.sort(cmpKeys)

func contains*[K, V](self: SortedTable[K, V], key: K): bool =
  self.indexOf(key) != -1

func get*[K, V](self: SortedTable[K, V], key: K): lent V =
  let i = self.indexOf(key)
  if i == -1:
    raise newException(KeyError, "key not found")
  self.entries[i].val

func getOr*[K, V](self: SortedTable[K, V], key: K, val: V): V =
  let i = self.indexOf(key)
  if i == -1:
    val
  else:
    self.entries[i].val

func getOrPut*[K, V](self: var SortedTable[K, V], key: K, val: sink V): lent V =
  mixin cmp
  let i = self.lowerIdx(key)
  if i == self.entries.len or cmpKeys(self.entries[i], key) != 0:
    self.entries.insert(SortedEntry[K,V](key: key, val: val), i)
  self.entries[i].val

func delete*[K, V](self: var SortedTable[K, V], key: K) =
  let i = self.indexOf(key)
  if i != -1:
    self.entries.delete(i)

func `[]`*[K, V](self: SortedTable[K, V], key: K): lent V =
  self.get(key)

func `[]`*[K, V](self: var SortedTable[K, V], key: K): var V =
  let i = self.indexOf(key)
  if i == -1:
    raise newException(KeyError, "key not found")
  self.entries[i].val

func `[]=`*[K, V](self: var SortedTable[K, V], key: sink K, val: sink V) =
  self.put(key, val)

func low*[K, V](self: SortedTable[K, V]): lent K =
  self.entries[0].key

func high*[K, V](self: SortedTable[K, V]): lent K =
  self.entries[self.entries.high].key

iterator items*[K, V](self: SortedTable[K, V]): lent SortedEntry[K,V] =
  for i in 0 ..< self.entries.len:
    yield self.entries[i]

iterator mitems[K,V](self: var SortedTable[K,V]): var SortedEntry[K,V] =
  for entry in self.entries.mitems:
    yield entry

iterator pairs*[K, V](self: SortedTable[K, V]): (lent K, lent V) =
  for i in 0 ..< self.entries.len:
    yield (self.entries[i].key, self.entries[i].val)

# ================
# Set sugar
# ================

func toSortedSet*[T](self: openArray[T], sorted = false): SortedSet[T] =
  toSortedSet(@self, sorted)

func contains*[T](self: SortedSet[T], val: T): bool =
  self.indexOf(val) != -1

func excl*[T](self: var SortedSet[T], val: T) =
  let i = self.indexOf(val)
  if i != -1:
    self.data.delete(i)

func getOr*[T](self: SortedSet[T], a, b: T): T =
  let i = self.indexOf(a)
  if i == -1:
    b
  else:
    self.data[i]

func `[]=`*[T](self: var SortedSet[T], val: sink T, included: bool) =
  if included:
    self.incl val
  else:
    self.excl val

func low*[T](self: SortedSet[T]): lent T =
  self.data[0]

func high*[T](self: SortedSet[T]): lent T =
  self.data[self.data.len - 1]

iterator items*[T](self: SortedSet[T]): lent T =
  for i in 0 ..< self.data.len:
    yield self.data[i]

iterator mitems[T](self: var SortedSet[T]): var T =
  for each in self.data.mitems:
    yield each

# ================
# Value Sugar
# ================

func `!`*(self: sink Value): Value =
  self.mark = true
  self

func `~`*(self: sink Value): Value =
  self.mark = false
  self

func `[]`*(self: Value, idx: int): lent Node =
  guard self.kind in {bList, bRec}, "invalid pos index"
  guard idx < self.vseq.len, "out of bounds"
  return self.vseq[idx]

func `[]=`*(self: var Value, idx: int, val: sink Node) =
  guard self.kind in {bList, bRec}, "invalid pos assignment"
  guard idx < self.vseq.len, "out of bounds"
  self.vseq[idx] = val

func `[]`*(self: Value, key: Node): lent Node =
  guard self.kind == bDict, "invalid value index"
  return self.vdict[key]

func `[]=`*(self: var Value, key: Node, val: sink Node) =
  guard self.kind == bDict, "invalid value assignment"
  self.vdict[key] = val

func contains*(self: Value, key: Node): bool =
  case self.kind
  of bList, bRec:
    key in self.vseq
  of bDict:
    self.vdict.indexOf(key) != -1
  of bSet:
    key in self.vset
  else: refuse "not a frame"

func incl*(self: var Value, val: sink Node) =
  guard self.kind == bSet, "invalid incl"
  self.vset.incl val

# ================
# Node Sugar
# ================

func `!`*(self: sink Node): Node =
  self.asValue.mark = true
  self

func `~`*(self: sink Node): Node =
  self.asValue.mark = false
  self

func Num*(n: SomeInteger, mark = false): Node =
  Plain(value: Value(kind: bNum, mark: mark, vnum: initNum(n)))

func Num*(n: BigInt, mark = false): Node =
  Plain(value: Value(kind: bNum, mark: mark, vnum: initNum(n)))

func Num*(s: sink string, mark = false): Node =
  Plain(value: atom(bNum, s, mark))

func Text*(s: sink string, mark = false): Node =
  Plain(value: atom(bText, s, mark))

func Sym*(s: sink string, mark = false): Node =
  Plain(value: atom(bSym, s, mark))

func Bytes*(s: string, mark = false): Node =
  Plain(value: atom(bBytes, s, mark))

func List*(els: sink seq[Node], mark = false): Node =
  Plain(value: frame(bList, els, mark))

func Rec*(els: sink seq[Node], mark = false): Node =
  Plain(value: frame(bRec, els, mark))

func Dict*(els: sink seq[(Node, Node)], mark = false): Node =
  var ravel = newSeqOfCap[Node](els.len * 2)
  for each in els.mitems:
    ravel.add(move each[0])
    ravel.add(move each[1])
  Plain(value: frame(bDict, ravel, mark))

func Set*(els: sink seq[Node], mark = false): Node =
  Plain(value: frame(bSet, els, mark))

proc rewriteIn(self: var Node, p: proc(n: var Value): bool, f: proc(n: var Node)): bool =
  case self
  of Bound: discard
  of Plain(n):
    if p(n): 
      f(self)
      return true
    case n.kind
    of bList, bRec:
      for each in n.vseq.mitems:
        if each.rewriteIn(p, f): result = true
    of bDict:
      for each in n.vdict.mitems:
        if each.key.rewriteIn(p, f): result = true
        if each.val.rewriteIn(p, f): result = true
      if result: n.vdict.normalize
    of bSet:
      for each in n.vset.mitems:
        if each.rewriteIn(p,f): result = true
      if result: n.vset.normalize
    else: discard

proc rewrite*(self: var Node, p: proc(n: var Value): bool, f: proc(n: var Node)) =
  discard self.rewriteIn(p, f)