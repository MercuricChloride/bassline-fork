{.experimental: "strictFuncs".}

import std/[algorithm, sequtils, options, hashes]
import ./strflavors
export strflavors, options

type
  SetObj* = object
    els: seq[Value]

  Entry* = tuple[key: Value, val: Value]

  Pair* = distinct int
  Slot* = distinct int

  DictObj* = object
    els: seq[Value]

  RecordObj* = object
    els: seq[Value]

  BlKind* = enum
    bNil   # nil
    bNum   # scalar types
    bText
    bSym
    bBytes
    bList  # frame types
    bRecord
    bDict
    bSet   

  Value* = object
    marked: bool
    case kind: BlKind
    of bNil:
      discard
    of bNum:
      num: DecimalString
    of bText, bSym:
      text: Utf8String
    of bBytes:
      bytes: seq[byte]
    of bList:
      listv: seq[Value]
    of bRecord:
      rec: RecordObj
    of bSet:
      elements: SetObj
    of bDict:
      entries: DictObj

  ValueLike* = concept x
    ## anything that can speak as a value or be made from a value
    ##
    ## toValue is total, fromValue is partial
    toValue(x) is Value
    fromValue(Value, typeof(x)) is Option[typeof(x)]

template fail(msg: untyped) =
  raise newException(ValueError, msg)

# ================ INDICES ================
# Slots are a flat offset just like a normal index
# Pairs have a stride of 2

func slot*(n: int): Slot =
  Slot(n)
func pair*(n: int): Pair =
  Pair(n)

func idx*(s: Slot): int = int(s)

func key*(p: Pair): Slot =
  slot(int(p) * 2)
func val*(p: Pair): Slot =
  slot(int(p) * 2 + 1)

func next*(s: Slot): Slot =
  slot s.idx + 1
func next*(p: Pair): Pair =
  pair int(p) + 1

func prev*(s: Slot): Slot =
  slot s.idx - 1
func prev*(p: Pair): Pair =
  pair int(p) - 1

func `==`*(a: Slot, b: int): bool =
  int(a) == b
func `==`*(a: Pair, b: int): bool =
  int(a) == b

func `<=`*(a, b: Pair): bool =
  int(a) <= int(b)
func `mid`*(pa, pb: Pair): Pair =
  let 
    a = int(pa)
    b = int(pb)
  if a < 0 or b < 0:
    return pair -1
  pair((a + b) div 2)

func valid*(s: Slot): bool =
  int(s) >= 0
func valid*(p: Pair): bool =
  int(p) >= 0

# ================ COLLECTIONS ================

func ravel*(v: Value): lent seq[Value] =
  ## every frame's contiguous payload in CE order; a dict's is its flat
  ## k v k v -- exactly what `children` already promises
  case v.kind
  of bList:   return v.listv
  of bRecord: return v.rec.els
  of bSet:    return v.elements.els
  of bDict:   return v.entries.els
  else: fail("ravel: not a frame")

template children*(v: Value): openArray[Value] =
  v.ravel.toOpenArray(0, v.ravel.len - 1)

func cmp*(a, b: Value): int
func cmp*(a, b: Entry): int
func `==`*(a, b: Value): bool

# ================ Flat Indexing ================

func slotCount*(pairs: int): int = pairs * 2
func pairCount*(slots: int): int = slots div 2

iterator pairIndex*(s: seq[Value]): Pair =
  ## the entries of a flat k v k v payload, by ordinal
  for n in 0 ..< pairCount(s.len):
    yield pair(n)

iterator pairIndex*(s: seq[Entry]): Pair =
  for n in 0 ..< len(s):
    yield pair(n)

iterator slotIndex*[T](s: T): Slot =
  for n in 0 ..< len(s):
    yield slot(n)

func `[]`*(xs: seq[Value], s: Slot): lent Value = xs[s.idx]
func `[]=`*(xs: var seq[Value], s: Slot, v: sink Value) = xs[s.idx] = v

func `[]`*(xs: seq[Value], p: Pair): (lent Value, lent Value) =
  (xs[p.key], xs[p.val])
func `[]=`*(xs: var seq[Value], p: Pair, v: (sink Value, sink Value)) =
  xs[p.key] = v[0]
  xs[p.val] = v[1]
func `[]`*(xs: seq[Entry], p: Pair): lent Entry =
  xs[p.int]

func flatten*(es: sink seq[Entry]): seq[Value] =
  ## pairs laid out flat
  result = newSeq[Value](slotCount(es.len))
  for i, e in es.toOpenArray(0, es.len - 1):
    result[pair(i)] = (e.key, e.val)

func dedupSorted*(xs: var seq[Value]) =
  ## drops repeats from an already sorted seq in place.
  var n = 0
  for i in 0 ..< xs.len:
    if n == 0 or xs[i] != xs[n - 1]:
      if n != i:
        xs[n] = move(xs[i])
      inc n
  xs.setLen(n)

func recordObj*(els: sink seq[Value]): RecordObj =
  if els.len == 0:
    fail("record: missing head")
  RecordObj(els: els)

func recordObj*(els: openArray[Value]): RecordObj =
  recordObj(@els)

func setObj*(els: sink seq[Value]): SetObj =
  result = SetObj(els: els)
  result.els.sort(cmp)
  result.els.dedupSorted

func setObj*(els: openArray[Value]): SetObj =
  setObj(@els)

func dictObj*(entries: sink seq[Entry]): DictObj =
  var es = entries
  es.sort(cmp)
  let flat = flatten(es)
  for p in pairIndex(flat):
    if p == 0: continue
    if flat[p.key] == flat[p.prev.key]:
      fail("dict: duplicate key")
  DictObj(els: flat)

func dictObj*(entries: openArray[Entry]): DictObj =
  dictObj(@entries)

template containerOps(T) =
  func `[]`*[I](v: T, i: I): lent Value =
    v.els[i]
  func high*(v: T): int =
    high(v.els)
  func len*(v: T): int =
    v.els.len
  func items*(v: T): lent seq[Value] =
    v.els
  iterator items*(v: T): lent Value =
    for el in v.els:
      yield el

containerOps(RecordObj)
containerOps(SetObj)

func len*(v: DictObj): int =
  ## The dict's ravel slot length
  v.els.len

func `[]`*(v: DictObj, p: Pair): (lent Value, lent Value) =
  v.els[p]
func `[]`*(v: DictObj, s: Slot): Value =
  v.els[s]

func highPair(v: DictObj): Pair =
  ## the last pair in a dict
  pair pairCount(v.len) - 1

func find*(v: DictObj, key: Value): Pair =
  ## returns a pair with key of key or an invalid pair
  var lo = pair 0
  var hi = v.highPair
  while lo <= hi:
    let 
      m = mid(lo, hi)
      c = cmp(v[m.key], key)
    if c == 0: 
      return m
    if c < 0: 
      lo = m.next
    else: hi = m.prev
  pair -1

# ================ RECOGNITION ================
func kind*(v: Value): BlKind =
  v.kind

func isKind*(v: Value, k: BlKind): bool =
  v.kind == k

func isKind*(v: Value, k: set[BlKind]): bool =
  k.contains(v.kind)

func isScalar*(v: Value): bool =
  v.isKind({bNil, bNum, bText, bSym, bBytes})

func isFrame*(v: Value): bool =
  return v.isKind({bList, bRecord, bDict, bSet})

# ================ ACCESSORS ================

func tag*(value: Value): 1 .. 9 =
  case value.kind
  of bNil: 1
  of bNum: 2
  of bText: 3
  of bSym: 4
  of bBytes: 5
  of bList: 6
  of bRecord: 7
  of bDict: 8
  of bSet: 9

func marked*(v: Value): bool =
  v.marked

func num*(v: Value): lent DecimalString =
  v.num

func text*(v: Value): lent Utf8String =
  v.text

func bytes*(v: Value): lent seq[byte] =
  v.bytes

func elements*(v: Value): lent SetObj =
  v.elements

func entries*(v: Value): lent DictObj =
  v.entries

func items*(v: Value): lent seq[Value] =
  case v.kind
  of bList:
    return v.listv
  of bRecord:
    return v.rec.els
  else:
    raise newException(ValueError, "items: must be list or record")

func head*(v: Value): lent Value =
  case v.kind
  of bList, bRecord:
    return v.children[0]
  else:
    raise newException(ValueError, "head: must be a list or record")

template tail*(v: Value): openArray[Value] =
  v.items.toOpenArray(min(1, v.items.len), v.items.len - 1)

func rec*(v: Value): lent RecordObj =
  v.rec

func payloadLength*(value: Value): int =
  case value.kind
  of bNum: value.num.len
  of bText, bSym: value.text.len
  of bBytes: value.bytes.len
  else: 0

iterator allChildren*(v: Value): lent Value {.closure.} =
  if v.isFrame:
    for child in v.children:
      yield child
      if child.isFrame:
        for deep in child.allChildren:
          yield deep

func hash*(v: Value): Hash =
  ## This is not a cryptographic hash!
  ##
  ## This is only used for things like tables & hash sets.
  ## Use lib/digest for cryptographic hashing
  var h: Hash = 0
  h = h !& hash(v.tag)
  h = h !& hash(v.marked)
  case v.kind
  of bNil:
    discard
  of bNum:
    h = h !& hash(string(v.num))
  of bText, bSym:
    h = h !& hash(string(v.text))
  of bBytes:
    h = h !& hash(v.bytes)
  of bList, bRecord, bSet, bDict:
    for c in v.children:
      h = h !& hash(c)
  result = !$h

# ================ ORDERING ================

  ## A comparison that's faithful to a lexicographic CE byte order.
  ##
  ## The CE encoding gives all values a header byte like:
  ## [tag:4][mark:1][len:3]
  ##
  ## cmp does the same ordering by: tag, mark, payload length, payload
  ##
  ## NOTE!
  ##
  ## Because frames are delimited with 0xA0 and since
  ## that byte is > all other CE header bytes it means that:
  ## a shorter frame is > a longer frame

func cmp*(a, b: seq[byte]): int =
  for i in 0 ..< min(a.len, b.len):
    let c = cmp(a[i], b[i])
    if c != 0:
      return c
  cmp(a.len, b.len)

func cmp*(a, b: seq[Value]): int =
  for i in 0 ..< min(a.len, b.len):
    let c = cmp(a[i], b[i])
    if c != 0:
      return c
  # Note! This looks backwards, but when comparing frames
  # the end byte (0xA0) is > all other header bytes
  # so a > b if a is a prefix of b
  cmp(b.len, a.len)

func cmp*(a, b: seq[Entry]): int =
  for i in 0 ..< min(a.len, b.len):
    let
      ae = a[i]
      be = b[i]
    let byKey = cmp(ae.key, be.key)
    if byKey != 0:
      return byKey
    let byValue = cmp(ae.val, be.val)
    if byValue != 0:
      return byValue
  # Note! This looks backwards, but when comparing frames
  # the end byte (0xA0) is > all other header bytes
  # so a > b if a is a prefix of b
  cmp(b.len, a.len)

func cmp*(a, b: Value): int =
  let byTag = cmp(a.tag, b.tag)
  if byTag != 0:
    return byTag

  let byMark = cmp(a.marked, b.marked)
  if byMark != 0:
    return byMark

  let byLen = cmp(a.payloadLength, b.payloadLength)
  if byLen != 0:
    return byLen

  case a.kind
  of bNil:
    0
  of bNum:
    cmp(a.num, b.num)
  of bText, bSym:
    cmp(a.text, b.text)
  of bBytes:
    cmp(a.bytes, b.bytes)
  of bList, bRecord, bSet, bDict:
    cmp(a.ravel, b.ravel)

func cmp*(a, b: Entry): int =
  cmp(a.key, b.key)

func `==`*(a, b: Value): bool =
  cmp(a, b) == 0

func `>`*(a, b: Value): bool =
  cmp(a, b) > 0

func `>=`*(a, b: Value): bool =
  cmp(a, b) >= 0

func `<`*(a, b: Value): bool =
  cmp(a, b) < 0

func `<=`*(a, b: Value): bool =
  cmp(a, b) <= 0

# ================ CONVERSIONS ================

func toValue*(v: sink Value): Value = v

func fromValue*(v: Value, t: typedesc[Value]): Option[Value] =
  some v

func mark*(v: sink Value, marked: bool = true): Value =
  result = v
  result.marked = marked

func unmark*(v: sink Value): Value =
  result = v
  result.marked = false

# ================ CONSTRUCTORS ================

func nilValue*(marked = false): Value =
  Value(kind: bNil, marked: marked)

func num*[T](text: T, marked = false): Value =
  Value(kind: bNum, marked: marked, num: toDecimal(text))

func text*[T](text: T, marked = false): Value =
  Value(kind: bText, text: toValidUtf8(text), marked: marked)

func sym*[T](text: T, marked = false): Value =
  Value(kind: bSym, text: toValidUtf8(text), marked: marked)

func bytes*(bytes: sink seq[byte], marked = false): Value =
  Value(kind: bBytes, bytes: bytes, marked: marked)

func bytes*(s: string, marked = false): Value =
  Value(kind: bBytes, bytes: s.toBytes, marked: marked)

func list*(items: sink seq[Value], marked = false): Value =
  Value(kind: bList, listv: items, marked: marked)
func list*(items: varargs[Value]): Value =
  list(@items, false)

func record*(rec: sink RecordObj, marked = false): Value =
  Value(kind: bRecord, rec: rec, marked: marked)

func set*(elements: sink SetObj, marked = false): Value =
  Value(kind: bSet, elements: elements, marked: marked)

func dict*(entries: sink DictObj, marked = false): Value =
  Value(kind: bDict, entries: entries, marked: marked)

template withVarArgs(name, constructor, el: untyped) =
  func name*(items: sink seq[el], marked = false): Value =
    name(constructor(items), marked)
  
  func name*(items: varargs[el]): Value =
    name(constructor(items), false)

withVarArgs(record, recordObj, Value)
withVarArgs(set, setObj, Value)
withVarArgs(dict, dictObj, Entry)