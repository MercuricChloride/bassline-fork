import std/[hashes, options]
import ./[shared, codec]
import ./codec/stream_decoder
export sorted_table, codec, options

refuseWith BasslineError

type
  OtherSet* = SortedSet[OtherValue]
  OtherDict* = SortedTable[OtherValue, OtherValue]
  OtherSeq* = seq[OtherValue]
  OtherRec* = Record[OtherValue]

  OtherValue* = object
    case kind*: Kind
    of bNil: discard
    of bNum:
      num*: BNum
    of bText, bSym:
      text*: string
    of bBytes:
      bytes*: string
    of bList, bRec:
      items*: OtherSeq
    of bDict:
      dict*: OtherDict
    of bSet:
      els*: OtherSet
    mark*: bool

func len*(self: OtherValue): int =
  case self.kind
  of bList, bRec:
    self.items.len
  of bDict:
    self.dict.len
  of bSet:
    self.els.len
  else: 0

func cmp*(a, b: OtherValue): int =
  template `??`(body) =
    result = body
    if result != 0: return
  ?? cmp(a.kind, b.kind)
  ?? cmp(a.mark, b.mark)
  case a.kind
  of bNil: discard
  of bNum:
    ?? cmpNums(a.num, b.num)
  of bText..bSym:
    ?? cmpShortlex(a.text.toBytes, b.text.toBytes)
  of bBytes:
    ?? cmpShortlex(a.bytes.toBytes, b.bytes.toBytes)
  of bList, bRec:
    for i in 0..<min(a.len, b.len):
      ?? cmp(a.items[i], b.items[i])
    ?? cmp(b.len, a.len)
  of bDict:
    for i in 0..<min(a.len, b.len):
      ?? cmp(a.dict.keys[i], b.dict.keys[i])
      ?? cmp(a.dict.vals[i], b.dict.vals[i])
    ?? cmp(b.len, a.len)
  of bSet:
    for i in 0..<min(a.len, b.len):
      ?? cmp(a.els.data[i], b.els.data[i])
    ?? cmp(b.len, a.len)

func `==`*(a, b: OtherValue): bool =
  cmp(a, b) == 0

func `<`*(a, b: OtherValue): bool =
  cmp(a, b) < 0

func `<=`*(a, b: OtherValue): bool =
  cmp(a, b) <= 0

proc toOtherValue*(view: sink RawValue): OtherValue =
  view.validate
  case view.kind
  of bNil:
    return OtherValue(kind: bNil, mark: view.mark)
  of bNum:
    return OtherValue(kind: bNum, num: initNum(view.payload), mark: view.mark)
  of bText:
    return OtherValue(kind: bText, text: view.payload, mark: view.mark)
  of bSym:
    return OtherValue(kind: bSym, text: view.payload, mark: view.mark)
  of bBytes:
    return OtherValue(kind: bBytes, bytes: view.payload, mark: view.mark)
  of bList, bRec:
    let
      kind: bList..bRec = view.kind
      mark = view.mark
    var
      items = newSeqOfCap[OtherValue](view.len)
    for child in view.mitems:
      items.add toOtherValue(move child)
    return OtherValue(kind: kind, mark: mark, items: move items)
  of bDict:
    let mark = view.mark
    var
      keys = newSeqOfCap[OtherValue](view.len div 2)
      vals = newSeqOfCap[OtherValue](view.len div 2)
    for k, v in view.mpairs:
      keys.add toOtherValue(move k)
      vals.add toOtherValue(move v)
    return OtherValue(kind: bDict, mark: mark,
      dict: toSortedTable(move keys, move vals, sorted = true))
  of bSet:
    let mark = view.mark
    var els = newSeqOfCap[OtherValue](view.len)
    for each in view.mitems:
      els.add toOtherValue(move each)
    return OtherValue(kind: bSet, mark: mark, els: toSortedSet(move els, sorted = true))

proc null*(T: typedesc[OtherValue], mark: bool): OtherValue =
  OtherValue(kind: bNil, mark: mark)
proc atom*(T: typedesc[OtherValue], s: sink string, kind: Kind, mark: bool): OtherValue =
  let k: bNum..bBytes = kind
  case k
  of bNum:
    OtherValue(kind: k, num: initNum(s), mark: mark)
  of bText, bSym:
    guard isValidUtf8(s.toBytes), "invalid utf8 bytes"
    OtherValue(kind: k, text: s, mark: mark)
  of bBytes:
    OtherValue(kind: k, bytes: s, mark: mark)
proc frame*(T: typedesc[OtherValue], s: sink seq[OtherValue], kind: Kind, mark: bool): OtherValue =
  let k: bList..bSet = kind
  case k
  of bList, bRec:
    OtherValue(kind: k, mark: mark, items: s)
  of bDict:
    guard s.len mod 2 == 0, "dict cannot have stranded keys"
    var
      keys = newSeqOfCap[OtherValue](s.len div 2)
      vals = newSeqOfCap[OtherValue](s.len div 2)
    for i in countup(0, s.len - 1, 2):
      guard keys.len == 0 or keys[^1] < s[i], "dict keys must be strictly ascending"
      keys.add move s[i]
      vals.add move s[i+1]
    OtherValue(kind: bDict, mark: mark,
      dict: toSortedTable(move keys, move vals, sorted = true))
  of bSet:
    for i in 1 ..< s.len:
      guard s[i-1] < s[i], "set elements must be strictly ascending"
    OtherValue(kind: bSet, mark: mark, els: toSortedSet(s, sorted = true))