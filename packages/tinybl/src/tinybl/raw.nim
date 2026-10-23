import ./ce

type RawValue* {.byref.} = object
  mark, valid: bool
  case kind: Kind
  of bNil: discard
  of bNum .. bBytes:
    bytes: string
  else:
    children: seq[RawValue]

func len*(self: RawValue): int =
  case self.kind
  of bNil .. bBytes: 0
  else: self.children.len

# ================
# Readable
# ================

proc null*(T: typedesc[RawValue], mark: bool): RawValue =
  RawValue(kind: bNil, mark: mark)

proc atom*(T: typedesc[RawValue], s: sink string, kind: Kind, mark: bool): RawValue =
  let k: bNum .. bBytes = kind
  RawValue(kind: k, mark: mark, bytes: s)

proc frame*(
    T: typedesc[RawValue], s: sink seq[RawValue], kind: Kind, mark: bool
): RawValue =
  let k: bList .. bSet = kind
  RawValue(kind: k, mark: mark, children: s)

# ================
# Walkable
# ================

proc valid*(self: RawValue): bool =
  self.valid

func kind*(self: RawValue): auto =
  self.kind

func mark*(self: RawValue): bool =
  self.mark

proc digits*(self: RawValue): lent string =
  return self.bytes

proc payload*(self: RawValue): lent string =
  return self.bytes

proc getChild*(self: RawValue, i: int): lent RawValue =
  return self.children[i]

iterator children*(self: RawValue): lent RawValue =
  for each in self.children:
    yield each

makeCmp(RawValue)

func validate*(self: var RawValue)

func validate*(self: var RawValue) {.raises: [].} =
  if self.valid:
    return
  case self.kind
  of bNil, bBytes:
    self.valid = true
    return
  of bNum:
    # numbers must have minimal decimal encoding
    self.valid = isValidInt(self.bytes.toBytes)
    return
  of bText, bSym:
    # text must be well formed utf8
    self.valid = isValidUtf8(self.bytes.toBytes)
    return
  else:
    discard

  for v in self.children.mitems:
    v.validate
    if not v.valid:
      return

  if self.kind == bRec:
    # records can't be empty
    if self.len == 0:
      return
  elif self.kind == bDict:
    # no stranded keys for dicts
    if not (self.len mod 2 == 0):
      return
    var i = 2
    while i < self.len:
      # dict keys must be strictly ascending
      if self.children[i - 2] < self.children[i]:
        i.inc 2
      else:
        return
  elif self.kind == bSet:
    var i = 1
    while i < self.len:
      # set elements must be strictly ascending
      if self.children[i - 1] < self.children[i]:
        inc i
      else:
        return
  self.valid = true

func setMark*(self: var RawValue, mark: bool) =
  self.mark = mark

iterator items*(self: RawValue): lent RawValue =
  for each in self.children:
    yield each

iterator pairs*(self: RawValue): (lent RawValue, lent RawValue) =
  var i = 1
  while i < self.len:
    yield (self.children[i - 1], self.children[i])
    i.inc 2