import std/streams
import ../shared
import ./partial

refuseWith CodecError

type
  Readable* = concept
    proc null(T: typedesc[Self], mark: bool): Self
    proc atom(T: typedesc[Self], bytes: sink string, kind: Kind, mark: bool): Self
    proc frame(T: typedesc[Self], members: sink seq[Self], kind: Kind, mark: bool): Self

proc readAtom[T: Readable](self: Stream, val: var T): bool =
  mixin null, atom
  if self.atEnd: return
  let startPos = self.getPosition
  try:
    var
      headerByte: byte
      med: uint8
      large: array[4, uint8]
      length: int
    self.read(headerByte)
    let (kind, mark, inlineLen) = headerData(headerByte)
    length = inlineLen
    if inlineLen == 7:
      self.read(med)
      guard med >= 7, "non minimal medium length"
      length = med.int
    if length == 255:
      self.read(large)
      length = 0
      for i in 0..3:
        length = (length shl 8) or int(large[i])
      guard length >= 255, "non minimal large length"
    if kind == bNil:
      val = T.null(mark)
    elif length > 0:
      var bytes = newString(length)
      let bytesRead = self.readData(addr(bytes[0]), length)
      guard bytesRead == bytes.capacity, "stream truncated"
      val = T.atom(move bytes, kind, mark)
    else:
      val = T.atom("", kind, mark)
    true
  except:
    self.setPosition(startPos)
    raise

proc readStream*[T: Readable](self: Stream, val: var T): bool =
  mixin null, frame
  if self.atEnd: return
  let pos = self.getPosition
  var headerByte: byte
  self.peek(headerByte)
  case partialKind(headerByte)
  of pvNil:
    let (_, mark, _) = headerData(headerByte)
    self.setPosition(pos + 1)
    val = T.null(mark)
    return true
  of pvCloseFrame:
    self.setPosition(pos + 1)
    return
  of pvOpenFrame:
    let (kind, mark, _) = headerData(headerByte)
    self.setPosition(pos + 1)
    var children = newSeqOfCap[T](10)
    var child: T
    while self.readStream(child):
      children.add move(child)
    val = T.frame(move children, kind, mark)
    return true
  of pvAtom:
    return self.readAtom(val)

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

func kind*(self: RawValue): auto =
  self.kind

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

func encodedSize*(self: RawValue, total: var int) =
  case self.kind
  of bNil:
    total += 1
  of bNum..bBytes:
    let len = self.bytes.len
    case len:
    of 0..6:
      total += 1 + len
    of 7..254:
      total += 2 + len
    else:
      total += 5 + len
  else:
    total += 2
    for each in self.children:
      each.encodedSize(total)

func encodedSize*(self: RawValue): int =
  self.encodedSize(result)

func mark*(self: RawValue): bool =
  self.mark

func payload*(self: sink RawValue): string =
  move self.bytes

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

proc writeHeader(stream: Stream, kind: Kind, mark: bool, len: int) =
  let
    k: byte = kind.tag
    m: byte = if mark: MarkBit else: 0
    l: byte = byte min(len, 7)
    h: byte = ((k shl 4) or m or l)
  stream.write h
  if len in 7..254:
    stream.write byte(len)
  elif len >= 255:
    stream.write 0xFF'u8
    for shift in [24, 16, 8, 0]:
      stream.write byte((len shr shift) and 0xFF)

proc writeScalar(self: RawValue, stream: Stream) =
  guard self.bytes.len <= MaxPayload.int, "payload too large"
  stream.writeHeader(self.kind, self.mark, self.bytes.len)
  if self.bytes.len > 0:
    stream.writeData(addr(self.bytes[0]), self.bytes.len)

proc writeValue*(self: RawValue, stream: Stream) =
  doAssert not stream.atEnd
  doAssert self.valid, "writing invalid value"
  case self.kind
  of bNil:
    stream.writeHeader(bNil, self.mark, 0)
  of bNum..bBytes:
    self.writeScalar(stream)
  else:
    stream.writeHeader(self.kind, self.mark, 0)
    for child in self:
      child.writeValue(stream)
    stream.write(EndByte)

proc ce*(self: RawValue): string =
  var str = newStringUninit(self.encodedSize)
  let s = newStringStream(str)
  self.writeValue(s)
  ensureMove str