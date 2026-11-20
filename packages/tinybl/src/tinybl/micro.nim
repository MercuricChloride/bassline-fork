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
from std/algorithm import sort, lowerBound, upperBound, binarySearch, isSorted
import std/[options, hashes]
import bigints
export options, hashes

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

type Header = object
  valid: bool
  partial: PartialValueKind
  kind: Kind
  mark: bool
  inlineLen: int

const headers = block:
  var all: array[byte, Header]
  for b in 0 .. 255:
    try:
      var h = Header(valid: true, partial: partialKind(byte b))
      if h.partial != pvCloseFrame:
        (h.kind, h.mark, h.inlineLen) = headerData(byte b)
      all[byte b] = h
    except BasslineError:
      discard
  all

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
# Frame Laws
# ================

proc inDictOrder*[T](ravel: openArray[T]): bool =
  mixin cmp
  if ravel.len mod 2 != 0:
    return false
  if ravel.len > 2:
    for i in countup(2, ravel.high, 2):
      if cmp(ravel[i-2], ravel[i]) >= 0:
        return false
  true

proc inSetOrder*[T](members: openArray[T]): bool =
  mixin cmp
  if members.len > 1:
    for i in 1..<members.len:
      if cmp(members[i-1], members[i]) >= 0:
        return false
  true

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

func initNum*(n: sink BigInt): BNum =
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

proc dedup*[T](self: var seq[T]) =
  mixin cmp
  if self.len < 2:
    return

  var els = newSeqOfCap[T](self.len - 1)
  els.add move self[0]

  for i in 1 ..< self.len:
    if cmp(self[i], els[^1]) > 0:
      els.add move self[i]

  self = els

proc allUnique*[T](self: openArray[T]): bool =
  ## Returns whether `self` contains distinct values
  ## This assumes `self` is strictly ascending: `self[i-1] < self[i]`
  mixin cmp
  for i in 1 ..< self.len:
    if cmp(self[i - 1], self[i]) == 0:
      return false
  true

# ================
# Assoc
# ================

type Assoc*[K, V] = object
  key: K
  val: V

proc `$`*[K, V](self: Assoc[K, V]): string =
  $self.key & ": " & $self.val

proc cmp*[K, V](a, b: Assoc[K, V]): int =
  mixin cmp
  cmp(a.key, b.key)

proc cmp*[K, V](a: Assoc[K, V], k: K): int =
  mixin cmp
  cmp(a.key, k)

proc `<`*[K, V](a, b: Assoc[K, V]): bool =
  cmp(a, b) < 0

proc initAssoc[K, V](key: sink K, val: sink V): Assoc[K, V] =
  Assoc[K, V](key: key, val: val)

# ================
# Sorted Table
# ================

type SortedTable*[K, V] = object
  data: seq[Assoc[K, V]]
  count: int

proc indexOf[K, V](self: SortedTable[K, V], key: K): int =
  self.data.binarySearch(key, cmp)

proc contains*[K, V](self: SortedTable[K, V], key: K): bool =
  self.indexOf(key) != -1

proc len*[K, V](self: SortedTable[K, V]): int =
  self.data.len

proc nth*[K, V](self: SortedTable[K, V], i: int): lent V {.inline.} =
  guard i in 0 ..< self.len*2, "invalid index"
  if i mod 2 == 0:
    return self.data[i div 2].key
  else:
    return self.data[i div 2].val

proc `[]`*[K, V](self: SortedTable[K, V], key: K): lent V =
  let i = self.indexOf(key)
  guard i != -1: "key not found"
  return self.data[i].val

proc `[]`*[K, V](self: var SortedTable[K, V], key: K): var V =
  let i = self.indexof(key)
  guard i != -1: "key not found"
  return self.data[i].val

proc `[]=`*[K, V](self: var SortedTable[K, V], key: sink K, val: sink V) =
  let i = self.indexOf(key)
  if i == -1:
    let idx = self.data.lowerBound(key, cmp)
    self.data.insert(initAssoc(key, val), idx)
  else:
    self.data[i].val = val

proc delete*[K, V](self: var SortedTable[K, V], key: K) =
  let i = self.indexOf(key)
  if i != -1:
    self.data.delete(i)

iterator items*[K, V](self: SortedTable[K, V]): lent V =
  for i in 0 ..< self.data.len:
    yield self.data[i].val

iterator pairs*[K, V](self: SortedTable[K, V]): (lent K, lent V) =
  for i in 0 ..< self.data.len:
    yield (self.data[i].key, self.data[i].val)

iterator mpairs*[K, V](self: var SortedTable[K, V]): (lent K, var V) =
  for i in 0 ..< self.data.len:
    yield (self.data[i].key, self.data[i].val)

proc hash*[K, V](self: SortedTable[K, V]): Hash =
  mixin hash
  for k, v in self:
    result = result !& k.hash !& v.hash
  result = !$result

proc take*[K, V](self: sink SortedTable[K, V]): seq[(K, V)] =
  result = newSeq[(K, V)](self.len)
  for i in 0 ..< self.len:
    result[i] = (move self.data[i].key, move self.data[i].val)

proc takeRavel*[T](self: sink SortedTable[T, T]): seq[T] =
  result = newSeqOfCap[T](self.len * 2)
  for i in 0 ..< self.len:
    result.add move self.data[i].key
    result.add move self.data[i].val

proc toSortedTable*[K, V](
    self: sink seq[(K, V)], sorted = false, unique = false
): SortedTable[K, V] =
  result.data.setLen(self.len)

  for i, e in self.mpairs:
    result.data[i] = initAssoc(move e[0], move e[1])

  if not sorted:
    result.data.sort(cmp[Assoc[K, V]])
  if not unique:
    result.data.dedup

proc toSortedTable*[K, V](
    self: openArray[(K, V)], sorted = false, unique = false
): SortedTable[K, V] =
  toSortedTable[K, V](@self, sorted, unique)

proc fromRavel*[T](
    self: sink seq[T], sorted = false, unique = false
): SortedTable[T, T] =
  guard self.len mod 2 == 0, "stranded key"
  var data = newSeqOfCap[(T, T)](self.len div 2)
  for i in countup(1, self.high, 2):
    data.add (move self[i - 1], move self[i])
  toSortedTable(data, sorted, unique)

proc fromRavel*[T](
    self: openArray[T], sorted = false, unique = false
): SortedTable[T, T] =
  fromRavel(@self, sorted, unique)

# ================
# Sorted Set
# ================

type SortedSet*[T] = object
  data: seq[T]

proc indexOf[T](self: SortedSet[T], item: T): int =
  mixin cmp
  self.data.binarySearch(item, cmp)

proc contains*[T](self: SortedSet[T], item: T): bool =
  self.indexOf(item) != -1

proc hash*[T](self: SortedSet[T]): Hash =
  mixin hash
  for each in self.data:
    result = result !& each.hash
  result = !$result

proc incl*[T](self: var SortedSet[T], item: sink T) =
  mixin cmp
  let i = self.data.lowerBound(item, cmp)

  if i < self.data.len and self.data[i] == item:
    return

  self.data.insert(item, i)

proc incl*[T](self: var SortedSet[T], other: SortedSet[T]) =
  for each in other:
    self.incl each

proc excl*[T](self: var SortedSet[T], item: T) =
  mixin cmp
  let i = self.indexOf(item)
  if i != -1:
    self.data.delete(i)

func len*[T](self: SortedSet[T]): int =
  self.data.len

func nth*[T](self: SortedSet[T], i: int): lent T {.inline.} =
  guard i in 0 ..< self.data.len, "invalid index"
  return self.data[i]

iterator items*[T](self: SortedSet[T]): lent T =
  for i in 0 ..< self.data.len:
    yield self.data[i]

proc take*[T](self: sink SortedSet[T]): seq[T] =
  self.data

proc toSortedSet*[T](self: sink seq[T], sorted = false, unique = false): SortedSet[T] =
  mixin cmp
  if not sorted:
    self.sort(cmp)
  if not unique:
    self.dedup
  result.data = self

proc toSortedSet*[T](self: openArray[T], sorted = false, unique = false): SortedSet[T] =
  toSortedSet[T](@self, sorted, unique)

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

method reified*(self: Live): Value {.base, sideEffect, raises: [BasslineError].} =
  refuse "reified must be implemented!"

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

func toValue*(self: sink Node): Value =
  case self
  of Plain(n):
    return n
  else: refuse("not data")

# ================
# Members
# ================

func isAtom*(self: Value): bool =
  self.kind in {bNil..bBytes}

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

func nth*(a: seq[Node], i: int): lent Node {.inline.} =
  guard i in 0..<a.len, "invalid index"
  return a[i]

func nth*(a: Value, i: int): lent Node {.inline.} =
  case a.kind
  of bList, bRec:
    return a.vseq.nth(i)
  of bDict:
    return a.vdict.nth(i)
  of bSet:
    return a.vset.nth(i)
  else: refuse("not a frame")

func cmp*(a, b: Value): int {.raises: [BasslineError].}
func cmp*(a, b: Node): int {.raises: [BasslineError].}
func cmp*(a, b: Live): int

func normalize*(self: var Value) =
  case self.kind
  of bDict:
    self.vdict.data.sort(cmp)
    guard self.vdict.data.allUnique, "dict normalized with duplicate keys"
  of bSet:
    self.vset.data.sort(cmp)
    guard self.vset.data.allUnique, "set normalized with duplicate elements"
  else: discard

iterator members*(a: Value): lent Node =
  if a.isFrame:
    for i in 0..<a.len:
      yield a.nth(i)

iterator members*(v: var Value, changed: var bool): var Node =
  template normalized(body) =
    var refused: bool
    try:
      body
    except CatchableError:
      refused = true
      raise
    finally:
      if changed and not refused:
        v.normalize
  case v.kind
  of bNil..bBytes: discard
  of bList, bRec:
    for each in v.vseq.mitems:
      yield each
  of bDict:
    normalized:
      for each in v.vdict.data.mitems:
        yield each.key
        yield each.val
  of bSet:
    normalized:
      for each in v.vset.data.mitems:
        yield each

# ================
# Order & hash
# ================

func cmp*(a, b: Live): int =
  cmp(cast[int](a), cast[int](b))

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
      a.nth(i) ?? b.nth(i)
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

func hash*(self: Value): Hash =
  template finish =
    return !$h
  var h = self.kind.hash !& self.mark.hash
  case self.kind
  of bNil:
    finish
  of bNum:
    h = h !& self.vnum.hash
    finish
  of bText, bSym, bBytes:
    h = h !& self.vstr.hash
    finish
  of bList, bRec:
    h = h !& self.vseq.hash
    finish
  of bDict:
    h = h !& self.vdict.hash
    finish
  of bSet:
    h = h !& self.vset.hash
    finish

func hash*(self: Node): Hash =
  case self
  of Bound(l): l.hash
  of Plain(v): v.hash

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

func frame*(kind: Kind, members: sink seq[Node], mark = false): Value =
  case kind
  of bList, bRec:
    guard kind == bList or members.len > 0, "record must have a head"
    Value(kind: kind, mark: mark, vseq: members)
  of bDict:
    guard members.len mod 2 == 0, "dict cannot have stranded keys"
    guard members.inDictOrder, "dict keys must be strictly ascending"
    let dict = fromRavel(members, sorted = true, unique = true)
    Value(kind: bDict, mark: mark, vdict: dict)
  of bSet:
    guard members.inSetOrder, "set elements must be strictly ascending"
    let els = toSortedSet(members, sorted = true, unique = true)
    Value(kind: bSet, mark: mark, vset: els)
  else:
    refuse "not a frame"

# ================
# Reification
# ================

func isPure*(self: Node): bool

func isPure*(self: Value): bool =
  for each in self.members:
    if not each.isPure: return false
  true

func isPure*(self: Node): bool =
  case self
  of Bound: false
  of Plain(v): v.isPure

proc reify*(self: var Node, deep = false): bool {.discardable.}

proc reify*(self: var Value, deep = false): bool {.discardable.} =
  for each in self.members(result):
    if each.reify(deep):
      result = true

proc reify*(self: var Node, deep = false): bool {.discardable.} =
  case self
  of Bound(l):
    self = Plain(value: l.reified)
    if deep:
      self.reify(true)
    true
  of Plain(self):
    self.reify(deep)

proc reified*(self: sink Node): Node =
  discard self.reify(true)
  self

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
  let h = headers[r.head[0]]
  var length = h.inlineLen
  if length == 7:
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
  val = atom(h.kind, move r.payload, h.mark)
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
    let h = headers[r.head[0]]
    if not h.valid:
      # this will raise with the right error
      # should probably handle this in a more
      # direct manner tho
      discard partialKind(r.head[0])
    case h.partial
    of pvOpenFrame:
      guard r.open.len < MaxDepth, "frames nested deeper than MaxDepth"
      let room = if r.frameCap > 0: r.frameCap else: DefaultFrameCap
      r.open.add OpenFrame(kind: h.kind, mark: h.mark, members: newSeqOfCap[Node](room))
      r.headLen = 0
      r.size += 1
      continue
    of pvCloseFrame:
      guard r.open.len > 0, "end at top level"
      var f = r.open.pop
      v = frame(f.kind, move f.members, f.mark)
    of pvNil:
      v = null(h.mark)
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

proc readAll*(r: var Reader, src: openArray[char]): seq[Value] =
  for each in r.readEach(src):
    result.add each

proc readAll*(src: openArray[char]): seq[Value] =
  var r = initReader()
  r.readAll(src)

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

proc writeAtom*(dst: var string, kind: Kind, mark: bool, payload: string) =
  guard payload.len <= MaxAtomPayload.int, "payload too large"
  dst.writeHeader(kind, mark, payload.len)
  dst.add payload

proc writeOpen*(dst: var string, kind: Kind, mark: bool) =
  guard kind in bList..bSet, "tried to open a non frame"
  dst.writeHeader(kind, mark, 0)

proc writeClose*(dst: var string) =
  dst.add char(EndByte)

proc write*(self: Node, enc: var Enc)

proc write*(n: Value, enc: var Enc) =
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
      each.write(enc)
    enc.writeClose

proc write*(self: Node, enc: var Enc) =
  case self
  of Bound:
    refuse "can only write a fully reified node"
  of Plain(v):
    v.write(enc)

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

converter toNum*(n: sink BigInt): BNum =
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
  x.asBig.powmod(power.initBigInt, modulus.initBigInt)

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

func abs*(n: sink BNum): BNum =
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

func `[]=`*(self: var Value, key: sink Node, val: sink Node) =
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

func contains*(self: Node, i: int): bool =
  case self
  of Bound: false
  of Plain(v):
    v.kind in {bList, bRec} and i < v.len

func contains*(self: Node, key: Node): bool =
  case self
  of Bound: false
  of Plain(v):
    case v.kind
    of bDict:
      key in v.vdict
    of bSet:
      key in v.vset
    else: false

func `[]`*(self: Node, i: int): lent Node =
  guard i in self, "invalid slot access"
  return self.asValue[i]

func `[]`*(self: Node, key: Node): lent Node =
  guard key in self, "inavlid key access"
  return self.asValue[key]

func `!`*(self: sink Node): Node =
  self.asValue.mark = true
  self

func `~`*(self: sink Node): Node =
  self.asValue.mark = false
  self

func Null*(mark = false): Node =
  Plain(value: null(mark))

func Num*(n: SomeInteger, mark = false): Node =
  Plain(value: Value(kind: bNum, mark: mark, vnum: initNum(n)))

func Num*(n: sink BigInt, mark = false): Node =
  Plain(value: Value(kind: bNum, mark: mark, vnum: initNum(n)))

func Num*(s: sink string, mark = false): Node =
  Plain(value: atom(bNum, s, mark))

func Text*(s: sink string, mark = false): Node =
  Plain(value: atom(bText, s, mark))

func Sym*(s: sink string, mark = false): Node =
  Plain(value: atom(bSym, s, mark))

func Bytes*(s: sink string, mark = false): Node =
  Plain(value: atom(bBytes, s, mark))

func List*(els: sink seq[Node], mark = false): Node =
  Plain(value: frame(bList, els, mark))

func Rec*(els: sink seq[Node], mark = false): Node =
  Plain(value: frame(bRec, els, mark))

func Dict*(els: sink seq[(Node, Node)], mark = false): Node =
  Plain(value: Value(kind: bDict, mark: mark, vdict: els.toSortedTable))

func Set*(els: sink seq[Node], mark = false): Node =
  Plain(value: Value(kind: bSet, mark: mark, vset: els.toSortedSet))

type
  BSet* = SortedSet[Node]
  BDict* = SortedTable[Node, Node]

proc rewrite*(self: var Node,
              p: proc(n: Value): bool,
              f: proc(n: var Node)): bool {.discardable.} =
  case self
  of Bound:
    return false
  of Plain(n):
    if p(n):
      f(self)
      return true
    for each in n.members(result):
      if each.rewrite(p,f):
        result = true
