{.experimental: "strictFuncs".}

import std/[algorithm, sequtils, options, hashes]
import ./strflavors
export strflavors, options

type
  SetObj* = object
    els: seq[Value]

  Entry* = tuple[key: Value, val: Value]

  DictObj* = object
    els: seq[Value]

  RecordObj* = object
    els: seq[Value]

  BlKind* = enum
    bNil   # nil
    bNum
    bText
    bSym
    bBytes # scalar types
    bList
    bRecord
    bDict
    bSet   # frame types

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

# ---------------- the flat pair layout ----------------
# a dict is held flat, k v k v
# so no other reader has to know it.

func slotCount*(pairs: int): int = pairs * 2
func pairCount*(slots: int): int = slots div 2
func keySlot*(pair: int): int = pair * 2
func valSlot*(pair: int): int = pair * 2 + 1

func flatten*(entries: sink seq[Entry]): seq[Value] =
  ## pairs laid out flat
  result = newSeq[Value](slotCount(entries.len))
  for i in 0 ..< entries.len:
    result[keySlot(i)] = move(entries[i].key)
    result[valSlot(i)] = move(entries[i].val)

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
  for i in 1 ..< pairCount(flat.len):
    if flat[keySlot(i)] == flat[keySlot(i - 1)]:
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

func len*(v: DictObj): int = pairCount(v.els.len)
func high*(v: DictObj): int = v.len - 1

func keyAt*(v: DictObj, i: int): lent Value = v.els[keySlot(i)]
func valAt*(v: DictObj, i: int): lent Value = v.els[valSlot(i)]

iterator items*(v: DictObj): Entry =
  for i in 0 ..< v.len:
    yield (key: v.keyAt(i), val: v.valAt(i))

func find*(v: DictObj, key: Value): int =
  var lo = 0
  var hi = v.len - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    let c = cmp(v.keyAt(mid), key)
    if c == 0: return mid
    if c < 0: lo = mid + 1
    else: hi = mid - 1
  -1

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

func high*(v: Value): int =
  case v.kind
  of bList:
    v.listv.high
  of bRecord:
    v.rec.high
  of bSet:
    v.elements.high
  of bDict:
    v.entries.high
  else:
    raise newException(ValueError, "high: must be a frame")

func head*(v: Value): lent Value =
  case v.kind
  of bList, bRecord:
    return v.children[0]
  else:
    raise newException(ValueError, "head: must be a list or record")

template tail*(v: Value): openArray[Value] =
  v.children[min(1, v.items.len) .. v.items.len - 1]

iterator tail*(v: Value): lent Value =
  case v.kind
  of bList, bRecord:
    for i, el in v.items:
      if i == 0:
        continue
      yield el
  else:
    raise newException(ValueError, "tail: must be a list or record")

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