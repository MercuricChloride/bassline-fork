{.experimental: "strictFuncs".}

import std/[algorithm, sequtils, options]
import strflavors

export strflavors, options

type
  SetOrder = object
  DictOrder = object

  Sorted*[Kind; T] = distinct seq[T]

  BlKind* = enum
    bNil # nil
    bNum
    bText
    bSym
    bBytes # scalar types
    bList
    bRecord
    bDict
    bSet # frame types

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
    of bList, bRecord:
      items: seq[Value]
    of bSet:
      elements: Sorted[SetOrder, Value]
    of bDict:
      entries: Sorted[DictOrder, (Value, Value)]

  ValueLike* = concept x
    ## anything that can speak as a value or be made from a value
    ##
    ## toValue is total, fromValue is partial
    toValue(x) is Value
    fromValue(Value, typeof(x)) is Option[typeof(x)]

const END_BYTE*: byte = 0xA0

# ================ SORTED ================
# We use a distinct type so we don't have to worry about
# improper usage polluting our values

template implSorted(ty, el: typedesc) =
  iterator items*(v: ty): lent el {.borrow.}

  func toOpenArray*(v: ty, first: int, last: int): openArray[el] {.borrow.}

  func low*(v: ty): int {.borrow.}

  func high*(v: ty): int {.borrow.}

  func len*(v: ty): int {.borrow.}

  func `[]`*[I: SomeOrdinal](v: ty, i: I): lent el =
    seq[el](v)[i]

implSorted(Sorted[SetOrder, Value], Value)

implSorted(Sorted[DictOrder, (Value, Value)], (Value, Value))

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

func kind*(v: Value): BlKind =
  v.kind

func marked*(v: Value): bool =
  v.marked

func num*(v: Value): lent DecimalString =
  v.num

func text*(v: Value): lent Utf8String =
  v.text

func bytes*(v: Value): lent seq[byte] =
  v.bytes

func elements*(v: Value): lent Sorted[SetOrder, Value] =
  v.elements

func entries*(v: Value): lent Sorted[DictOrder, (Value, Value)] =
  v.entries

func items*(v: Value): lent seq[Value] =
  v.items

func head*(v: Value): lent Value =
  v.items[0]

func tail*(v: Value): seq[Value] =
  v.items[1 .. high(v.items)]

func payloadLength*(value: Value): int =
  case value.kind
  of bNum: value.num.len
  of bText, bSym: value.text.len
  of bBytes: value.bytes.len
  else: 0

iterator children*(v: Value): lent Value =
  ## Iterates a value as though it was a list
  ##
  ## So iteration of a dictionary yields key then yields val
  ## sequentially
  case v.kind
  of bList, bRecord:
    for item in v.items:
      yield item
  of bDict:
    for (k, v) in v.entries:
      yield k
      yield v
  of bSet:
    for item in v.elements:
      yield item
  else:
    discard

iterator allChildren*(v: Value): lent Value {.closure.} =
  for child in v.children:
    yield child
    for deep in child.allChildren:
      yield deep

# ================ RECOGNITION ================

func isKind*(v: Value, k: BlKind): bool =
  v.kind == k

func isKind*(v: Value, k: set[BlKind]): bool =
  k.contains(v.kind)

func isScalar*(v: Value): bool =
  v.isKind({bNil, bNum, bText, bSym, bBytes})

func isFrame*(v: Value): bool =
  v.isKind({bList, bRecord, bDict, bSet})

# ================ ORDERING ================

func cmp*(a, b: Value): int
  ## A comparison that's faithful to a lexicographic CE byte order.
  ##
  ## The CE encoding gives all values a header byte like:
  ## [tag:4][mark:1][len:3]
  ##
  ## cmp does the same ordering by: tag, mark, payload length, payload
  ##
  ## NOTE!
  ##
  ## Because frames are delimited with END_BYTE (0xA0) and since
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

func cmp*(a, b: seq[(Value, Value)]): int =
  for i in 0 ..< min(a.len, b.len):
    let
      (aKey, aVal) = a[i]
      (bKey, bVal) = b[i]
    let byKey = cmp(aKey, bKey)
    if byKey != 0:
      return byKey
    let byValue = cmp(aVal, bVal)
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
  of bList, bRecord:
    cmp(a.items, b.items)
  of bSet:
    cmp(seq[Value](a.elements), seq[Value](b.elements))
  of bDict:
    cmp(seq[(Value, Value)](a.entries), seq[(Value, Value)](b.entries))

func cmpKeys(a, b: (Value, Value)): int =
  cmp(a[0], b[0])

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

func toValue*(v: Value): Value =
  v

func fromValue*(v: Value, t: typedesc[Value]): Option[Value] =
  some v

func mark*(v: sink Value): Value =
  result = v
  result.marked = true

func unmark*(v: sink Value): Value =
  result = v
  result.marked = false

# ================ CONSTRUCTORS ================

func nilValue*(marked = false): Value =
  Value(kind: bNil, marked: marked)

func num*(text: string, marked = false): Value =
  Value(kind: bNum, marked: marked, num: toDecimal(text))

func num*(d: DecimalString, marked = false): Value =
  Value(kind: bNum, marked: marked, num: d)

func text*[T](text: T, marked = false): Value =
  Value(kind: bText, text: toValidUtf8(text), marked: marked)

func sym*[T](text: T, marked = false): Value =
  Value(kind: bSym, text: toValidUtf8(text), marked: marked)

func toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], addr s[0], s.len)

func bytes*(bytes: sink seq[byte], marked = false): Value =
  Value(kind: bBytes, bytes: bytes, marked: marked)

func bytes*(s: string, marked = false): Value =
  Value(kind: bBytes, bytes: s.toBytes, marked: marked)

func list*(items: sink seq[Value], marked = false): Value =
  Value(kind: bList, items: items, marked: marked)

func list*(items: varargs[Value]): Value =
  list(@items, false)

func record*(items: sink seq[Value], marked = false): Value =
  if items.len == 0:
    raise newException(ValueError, "record: missing head")
  Value(kind: bRecord, items: items, marked: marked)

func record*(items: varargs[Value]): Value =
  record(@items, false)

func set*(elements: sink seq[Value], marked = false): Value =
  var es = elements
  es.sort(cmp)
  var unique = es.deduplicate(true)
  Value(kind: bSet, marked: marked, elements: Sorted[SetOrder, Value](unique))

func set*(elements: varargs[Value]): Value =
  set(@elements, false)

func dict*(entries: sink seq[(Value, Value)], marked = false): Value =
  var es = entries
  es.sort(cmpKeys)
  for i in 1 ..< es.len:
    if cmp(es[i - 1][0], es[i][0]) == 0:
      raise newException(ValueError, "dict: duplicate key")
  Value(kind: bDict, marked: marked, entries: Sorted[DictOrder, (Value, Value)](es))
