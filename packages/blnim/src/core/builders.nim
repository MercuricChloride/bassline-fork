import ./btree
export btree

type
  Kind* = enum
    bNil,
    bNum, bText, bSym, bBytes,
    bList, bRec, bDict, bSet

  Value* = object
    marked*: bool
    case kind*: Kind
    of bNil: discard
    of bNum:
      num*: int
    of bText, bSym:
      text*: string
    of bBytes:
      bytes*: seq[byte]
    of bList, bRec:
      items*: seq[Value]
    of bDict:
      dict*: BTree[Value, Value]
    of bSet:
      elements*: BTree[Value, bool]

func null*(marked = false): Value =
  Value(kind: bNil, marked: marked)

func num*(n: int, marked = false):  Value =
  Value(kind: bNum, marked: marked, num: n)

func text*(t: string, marked = false): Value =
  Value(kind: bText, text: t, marked: marked)

func sym*(t: string, marked = false): Value =
  Value(kind: bSym, text: t, marked: marked)

func bytes*(b: sink seq[byte], marked = false): Value =
  Value(kind: bBytes, bytes: b, marked: marked)

func initList*(marked = false): Value =
  Value(kind: bList, items: @[], marked: marked)

func initRec*(head: Value, marked = false): Value =
  Value(kind: bRec, items: @[head], marked: marked)

func initDict*(marked = false): Value =
  Value(kind: bDict, dict: initBTree[Value, Value](), marked: marked)

func initSet*(marked = false): Value =
  Value(kind: bSet, elements: initBTree[Value, bool](), marked: marked)

template diff(a, b) =
  result = cmp(a, b)
  if result != 0: return

func cmp*(a, b: Value): int =
  diff a.kind, b.kind
  diff a.marked, b.marked
  case a.kind
  of bNil: discard
  of bNum:
    let
      sa = $(a.num)
      sb = $(b.num)
    diff sa.len, sb.len
    for i in 0..<min(sa.len, sb.len):
      diff sa[i], sb[i]
  of bText, bSym:
    diff a.text.len, b.text.len
    for i in 0..<min(a.text.len, b.text.len):
      diff a.text[i], b.text[i]
  of bBytes:
    diff a.bytes.len, b.bytes.len
    for i in 0..<min(a.bytes.len, b.bytes.len):
      diff a.bytes[i], b.bytes[i]
  of bList, bRec:
    for i in 0 ..< min(a.items.len, b.items.len):
      diff a.items[i], b.items[i]
    # looks backwards, but matches that frames are terminated with 0xA0
    # which causes shorter frames to be > longer frames
    diff b.items.len, a.items.len
  of bDict:
    var
      wa = iterator (): (Value, Value) =
        for k, v in a.dict: yield (k, v)
      wb = iterator (): (Value, Value) =
        for k, v in b.dict: yield (k, v)
    while true:
      let
        (ka, va) = wa()
        (kb, vb) = wb()
      if finished(wa) or finished(wb):
        # looks backwards, but matches that frames are terminated with 0xA0
        # which causes shorter frames to be > longer frames
        diff not finished(wb), not finished(wa)
        break
      diff ka, kb
      diff va, vb
  of bSet:
    var wa = iterator (): Value =
      for k, _ in a.elements: yield k
    var wb = iterator (): Value =
      for k, _ in b.elements: yield k
    while true:
      let ka = wa()
      let kb = wb()
      if finished(wa) or finished(wb):
        # looks backwards, but matches that frames are terminated with 0xA0
        # which causes shorter frames to be > longer frames
        diff not finished(wb), not finished(wa)
        break
      diff ka, kb

func `==`*(a, b: Value): bool =
  cmp(a, b) == 0
func `<`*(a, b: Value): bool =
  cmp(a, b) < 0
func `>`*(a, b: Value): bool =
  cmp(a, b) > 0
func `<=`*(a, b: Value): bool =
  cmp(a, b) <= 0
func `>=`*(a, b: Value): bool =
  cmp(a, b) >= 0

# ================ Frame constructors ================

func toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

func initList*(items: sink seq[Value], marked = false): Value =
  Value(kind: bList, items: items, marked: marked)

func initRec*(items: sink seq[Value], marked = false): Value =
  doAssert items.len > 0, "a record needs a head"
  Value(kind: bRec, items: items, marked: marked)

proc initSet*(items: sink seq[Value], marked = false): Value =
  result = initSet(marked)
  for x in items:
    result.elements[x] = true

proc initDict*(entries: sink seq[(Value, Value)], marked = false): Value =
  result = initDict(marked)
  for (k, v) in entries:
    result.dict[k] = v

func toValue*(v: Value): Value = v
func toValue*(i: int): Value = num(i)
func toValue*(i: int64): Value = num(int(i))
func toValue*(s: string): Value = text(s)
func toValue*(b: seq[byte]): Value = bytes(b)

func toValue*[T](xs: seq[T]): Value =
  mixin toValue
  result = initList()
  for x in xs:
    result.items.add toValue(x)