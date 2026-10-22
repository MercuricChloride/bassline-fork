import std/streams
import ../shared
import ./partial

refuseWith CodecError

type
  Readable* = concept
    proc null(T: typedesc[Self], mark: bool): Self
    proc atom(T: typedesc[Self], bytes: sink string, kind: Kind, mark: bool): Self
    proc frame(T: typedesc[Self], members: sink seq[Self], kind: Kind, mark: bool): Self

  Walkable* = concept
    proc valid(self: Self): bool
    proc kind(self: Self): Kind
    proc mark(self: Self): bool
    proc digits(self: Self): string
    proc payload(self: Self): string
    iterator children(self: Self): Self

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

proc writeAtom(stream: Stream, kind: Kind, mark: bool, payload: string) =
  guard payload.len <= MaxPayload.int:
    echo "payload size: ", payload.len
    "payload too large"
  stream.writeHeader(kind, mark, payload.len)
  stream.write payload

proc writeValue*[T: Walkable](stream: Stream, val: T) =
  doAssert val.valid, "writing invalid value"
  case val.kind
  of bNil:
    stream.writeHeader(bNil, val.mark, 0)
  of bNum:
    stream.writeAtom(val.kind, val.mark, val.digits)
  of bText..bBytes:
    stream.writeAtom(val.kind, val.mark, val.payload)
  else:
    stream.writeHeader(val.kind, val.mark, 0)
    for child in val.children:
      stream.writeValue(child)
    stream.write(EndByte)