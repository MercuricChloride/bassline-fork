include pkg/prelude
import ./types

type
  RawValue* = object
    marked: bool
    case kind: BlKind
    of bNil: discard
    of bNum, bText, bSym, bBytes:
      payload: seq[byte]
    of bList, bRecord, bDict, bSet:
      els: seq[RawValue]

func kind*(v: RawValue): BlKind = v.kind
func marked*(v: RawValue): bool = v.marked
func size*(v: RawValue): int =
  if v.kind in SizedKinds:
    return v.payload.len
func els*(v: RawValue): lent seq[RawValue] =
  v.els

func payload*(v: RawValue): lent seq[byte] =
  if v.kind notin SizedKinds:
    refuse "payload: not a sized kind"
  return v.payload

# Forward decl
func validatePayload*(b: openArray[byte], kind: BlKind)
func validateFrame*(els: openArray[Value], kind: BlKind)

# Raw Value Stuff
func rawValue*(payload: sink seq[byte], 
  kind: range[bNum..bBytes] = bBytes, marked = false): RawValue =
  if kind notin AtomKinds:
    refuse "invalid atom kind"
  result = RawValue(kind: kind, marked: marked, payload: payload)
  validatePayload(result.payload, kind)

func rawValue*(s: sink string, 
  kind: range[bNum..bBytes] = bText, marked = false): RawValue =
  rawValue(@(s.toOpenArrayByte(0, s.high)), kind, marked)

func rawValue*(els: sink seq[RawValue], kind: range[bList..bSet] = bList, marked = false): RawValue =
  if kind notin FrameKinds:
    refuse "invalid frame kind"
  result = RawValue(kind: kind, marked: marked, els: els)
  validateFrame(result.els, kind)

func rawValue*(marked = false): RawValue =
  RawValue(kind: bNil, marked: marked)

func validateFrame*(els: openArray[Value], kind: BlKind) =
  case kind
  of bList: discard
  of bRecord:
    if els.len == 0: refuse "record with no head"
  of bSet:
    for i in 1..<els.len:
      let c = cmp(els[i-1], els[i])
      if c > 0:
        refuse "invalid set: members out of order"
      elif c == 0:
        refuse "invalid set: duplicate member"
  of bDict:
    if els.len mod 2 != 0:
      refuse "invalid dict: key missing its value"
    var i = 2
    while i < els.len:
      if cmp(els[i - 2], els[i]) >= 0:
        refuse "dict keys out of order or duplicated"
      i += 2
  else:
    refuse "validateFrame: not a frame kind"

func validateInt*(chars: openArray[char]) =
  let start = if chars.len > 0 and chars[0] == '-': 1 else: 0
  if chars.len == start:
    refuse("validateInt: effective length cannot be 0")
  for c in chars:
    if c in {'0'..'9'}: continue
    if c == '-': continue
    refuse("validateInt: invalid char outside of [0-9]")
  if chars[start] == '0' and chars.len - start > 1:
    refuse("validateInt: ")
  if chars == ['-', '0']:
    refuse("validateInt: [-0] not a valid int")

func isCont(b: byte): bool =
  (b and 0xC0) == 0x80

func validateText*(s: openArray[byte]) =
  var i = 0
  while i < s.len:
    case s[i]
    of 0x00 .. 0x7F:
      inc i
    of 0xC2 .. 0xDF:
      if i + 1 >= s.len or not isCont(s[i + 1]):
        refuse("validateText: invalid")
      i += 2
    of 0xE0:
      if i + 2 >= s.len or s[i + 1] notin 0xA0'u8 .. 0xBF'u8 or not isCont(s[i + 2]):
        refuse("validateText: invalid")
      i += 3
    of 0xE1 .. 0xEC, 0xEE .. 0xEF:
      if i + 2 >= s.len or not isCont(s[i + 1]) or not isCont(s[i + 2]):
        refuse("validateText: invalid")
      i += 3
    of 0xED:
      if i + 2 >= s.len or s[i + 1] notin 0x80'u8 .. 0x9F'u8 or not isCont(s[i + 2]):
        refuse("validateText: invalid")
      i += 3
    of 0xF0:
      if i + 3 >= s.len or s[i + 1] notin 0x90'u8 .. 0xBF'u8 or
          not isCont(s[i + 2]) or not isCont(s[i + 3]):
        refuse("validateText: invalid")
      i += 4
    of 0xF1 .. 0xF3:
      if i + 3 >= s.len or not isCont(s[i + 1]) or
          not isCont(s[i + 2]) or not isCont(s[i + 3]):
        refuse("validateText: invalid")
      i += 4
    of 0xF4:
      if i + 3 >= s.len or s[i + 1] notin 0x80'u8 .. 0x8F'u8 or
          not isCont(s[i + 2]) or not isCont(s[i + 3]):
        refuse("validateText: invalid")
      i += 4
    else:
      refuse("validateText: invalid")

func validatePayload*(b: openArray[byte], kind: BlKind) =
  case kind
  of bNil, bBytes, bList: discard
  of bNum: validateInt(b.toOpenArrayChar(0, b.high))
  of bText, bSym: validateText(b)
  else:
    refuse "validatePayload: not an atom kind"