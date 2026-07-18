{.experimental: "strictFuncs".}

import std/[sequtils, algorithm, options]
import strflavors/[decimal, utf8]
export decimal, utf8

type
  BlKind* = enum
    bNil,                       # nil
    bNum, bText, bSym, bBytes,  # scalar types
    bList, bRecord, bDict, bSet # frame types

  SetOrder* = object
  DictOrder* = object

  Sorted*[Kind; T] = distinct seq[T]

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
    ## anything that can speak as a value and be made from a value;
    ## toValue is total, fromValue is partial
    toValue(x) is Value
    fromValue(default(Value), typeof(x)) is Option[typeof(x)]

const
  scalarKinds: set[BlKind] = {bNil, bNum, bText, bSym, bBytes}
  frameKinds: set[BlKind] = {bList, bRecord, bDict, bSet}
  END_BYTE*: byte = 0xA0

# ================ SORTED ================
# We use a distinct type so we don't have to worry about
# improper usage polluting our values
# TODO: I haven't fully locked this down yet

iterator items*[K; T](s: Sorted[K, T]): lent T =
  for x in seq[T](s):
    yield x

func len*[K; T](s: Sorted[K, T]): int =
  seq[T](s).len

func `[]`*[K; T](s: Sorted[K, T]; i: int): lent T =
  seq[T](s)[i]

# ================ RECOGNITION ================

func isScalar*(value: Value): bool = scalarKinds.contains(value.kind)
func isFrame*(value: Value): bool = frameKinds.contains(value.kind)

func tag*(value: Value): 1..9 =
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

func payloadLength*(value: Value): int =
  case value.kind
  of bNum:
    value.num.len
  of bText, bSym:
    value.text.len
  of bBytes:
    value.bytes.len
  else:
    0

# ================ ACCESSORS ================

func num*(v: Value): lent DecimalString = v.num
func text*(v: Value): lent Utf8String = v.text
func bytes*(v: Value): lent seq[byte] = v.bytes
func items*(v: Value): lent seq[Value] = v.items
func elements*(v: Value): lent Sorted[SetOrder, Value] = v.elements
func entries*(v: Value): lent Sorted[DictOrder, (Value, Value)] = v.entries
func kind*(v: Value): BlKind = v.kind
func marked*(v: Value): bool = v.marked
func head*(v: Value): Value =
  v.items[0]
func tail*(v: Value): seq[Value] =
  v.items[1..high(v.items)]

# ================ ORDERING ================

func cmp*(a, b: Value): int

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
  ## cmp is a comparison that's faithful to CE byte order
  ## The CE encoding gives all values a header byte like:
  ## [tag:4][mark:1][len:3]
  ## cmp does the same ordering by:
  ## tag, mark, payload length, payload
  ## This implies if cmp(a, b) == 0
  ## then the values consist of the same CE bytes
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

func `==`*(a, b: Value): bool = cmp(a, b) == 0
func `>`*(a, b: Value): bool = cmp(a, b) > 0
func `>=`*(a, b: Value): bool = cmp(a, b) >= 0
func `<`*(a, b: Value): bool = cmp(a, b) < 0
func `<=`*(a, b: Value): bool = cmp(a, b) <= 0

# ================ CONSTRUCTORS ================


func toValue*(v: Value): Value = v
func fromValue*(v: Value; t: typedesc[Value]): Option[Value] = some v

func nilValue*(marked = false): Value =
  Value(kind: bNil, marked: marked)

func num*(text: string; marked = false): Value =
  Value(kind: bNum, marked: marked, num: text.toDecimal)

func num*(d: DecimalString; marked = false): Value =
  ## Already canonical
  Value(kind: bNum, marked: marked, num: d)

func text*[T](text: T; marked = false): Value =
  Value(kind: bText, text: text.toValidUtf8, marked: marked)

func sym*[T](text: T, marked = false): Value =
  Value(kind: bSym, text: text.toValidUtf8, marked: marked)

func bytes*(bytes: sink seq[byte]; marked = false): Value =
  Value(kind: bBytes, bytes: bytes, marked: marked)

func bytes*(s: string; marked = false): Value =
  var buf = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr buf[0], addr s[0], s.len)
  Value(kind: bBytes, bytes: buf, marked: marked)

func list*(items: sink seq[Value]; marked = false): Value =
  Value(kind: bList, items: items, marked: marked)

func list*(items: varargs[Value]): Value =
  list(@items, false)

func record*(items: sink seq[Value]; marked = false): Value =
  if items.len == 0:
    raise newException(ValueError, "record: missing head")
  Value(kind: bRecord, items: items, marked: marked)

func record*(items: varargs[Value]): Value =
  record(@items, false)

func set*(elements: sink seq[Value]; marked = false): Value =
  var es = elements
  es.sort(cmp)

  var unique = es.deduplicate(true)
  Value(kind: bSet, marked: marked, elements: Sorted[SetOrder, Value](unique))

func set*(elements: varargs[Value]): Value =
  set(@elements, false)

func cmpKeys(a, b: (Value, Value)): int =
  cmp(a[0], b[0])

func dict*(entries: sink seq[(Value, Value)]; marked = false): Value =
  var es = entries
  es.sort(cmpKeys)
  for i in 1 ..< es.len:
    if cmp(es[i - 1][0], es[i][0]) == 0:
      raise newException(ValueError, "dict: duplicate key")
  Value(
    kind: bDict,
    marked: marked,
    entries: Sorted[DictOrder, (Value, Value)](es)
  )

func mark*(v: sink Value): Value =
  result = v
  result.marked = true

func unmark*(v: sink Value): Value =
  result = v
  result.marked = false
