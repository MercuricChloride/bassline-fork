import ../shared

refuseWith BasslineError

type
  RawValue* {.byref.} = object
    mark, valid: bool
    case kind: Kind
      of bNil: discard
      of bNum..bBytes:
        bytes: string
      else:
        children: seq[RawValue]

func len*(self: RawValue): int =
  self.children.len

func cmp*(a, b: RawValue): int =
  template `??`(body) =
    result = body
    if result != 0: return
  ?? cmp(a.kind, b.kind)
  ?? cmp(a.mark, b.mark)
  case a.kind
  of bNil: discard
  of bNum..bBytes:
    ?? cmpShortlex(a.bytes.toBytes, b.bytes.toBytes)
  of bList, bRec, bSet:
    for i in 0..<min(a.len, b.len):
      ?? cmp(a.children[i], b.children[i])
    ?? cmp(b.len, a.len)
  of bDict:
    var i = 1
    while i < min(a.len, b.len):
      ?? cmp(a.children[i-1], b.children[i-1])
      ?? cmp(a.children[i], b.children[i])
      i.inc 2
    ?? cmp(b.len, a.len)

func `==`*(a, b: RawValue): bool =
  cmp(a, b) == 0
func `<`*(a, b: RawValue): bool =
  cmp(a, b) < 0
func `<=`*(a, b: RawValue): bool =
  cmp(a, b) <= 0

func validate*(self: var RawValue)

proc null*(T: typedesc[RawValue], mark: bool): RawValue =
  RawValue(kind: bNil, mark: mark)
proc atom*(T: typedesc[RawValue], s: sink string, kind: Kind, mark: bool): RawValue =
  let k: bNum..bBytes = kind
  RawValue(kind: k, mark: mark, bytes: s)
proc frame*(T: typedesc[RawValue], s: sink seq[RawValue], kind: Kind, mark: bool): RawValue =
  let k: bList..bSet = kind
  RawValue(kind: k, mark: mark, children: s)

func validate*(self: var RawValue) =
  if self.valid: return
  case self.kind
  of bNil, bBytes: 
    self.valid = true
    return
  of bNum: 
    self.valid = isValidInt(self.bytes.toBytes)
    return
  of bText, bSym: 
    self.valid = isValidUtf8(self.bytes.toBytes)
    return
  else: discard
  
  for v in self.children.mitems:
    v.validate
    if not v.valid: return

  if self.kind == bDict:
    var i=2
    while i < self.len:
      if self.children[i-2] < self.children[i]:
        i.inc 2
      else: return
  elif self.kind == bSet:
    var i=1
    while i < self.len:
      if self.children[i-1] < self.children[i]:
        inc i
      else: return
      inc i
  self.valid = true

func mark*(self: RawValue): bool =
  self.mark

iterator items*(self: RawValue): lent RawValue =
  for each in self.children:
    yield each

iterator mitems*(self: sink RawValue): var RawValue =
  for each in self.children.mitems:
    yield each

iterator pairs*(self: RawValue): (lent RawValue, lent RawValue) =
  var i = 1
  while i < self.len:
    yield (self.children[i-1], self.children[i])
    i.inc 2

iterator mpairs*(self: sink RawValue): (var RawValue, var RawValue) =
  var i = 1
  while i < self.len:
    yield (self.children[i-1], self.children[i])
    i.inc 2

# ================
# Walkable
# ================

proc valid*(self: RawValue): bool =
  self.valid

proc digits*(self: RawValue): string =
  self.bytes

proc payload*(self: RawValue): lent string =
  return self.bytes

iterator children*(self: RawValue): lent RawValue =
  for each in self.children:
    yield each

func kind*(self: RawValue): auto =
  self.kind