import ../shared

refuseWith CodecError

type
  HeaderData* = tuple
    kind: Kind
    mark: bool
    inlineLen: int

  PartialValueKind* = enum
    pvNil, pvAtom, pvOpenFrame, pvCloseFrame

  PartialValue* = object
    offset*: int
    case kind*: PartialValueKind
    of pvAtom:
      payloadLen*: uint32
    else: discard

func skipLen*(payloadLen: uint32): int =
  case payloadLen
  of 0..6: 1
  of 7..254: 2
  else: 6

func headerData*(b: byte): HeaderData =
  let
    tag = int(b shr 4)
    mark = (b and MarkBit) != 0
    len = int(b and 7)
  guard tag in 1..9, ("invalid tag: " & $tag)
  (Kind(tag - 1), mark, len)

func partialKind*(b: byte): PartialValueKind =
  if b == EndByte:
    return pvCloseFrame
  let h = headerData(b)
  case h.kind
  of bNum..bBytes: 
    pvAtom
  of bNil:
    guard h.inlineLen == 0, "nil lenBits must be 0"
    pvNil
  of bList..bSet:
    guard h.inlineLen == 0, "frame lenBits must be 0"
    pvOpenFrame

iterator partialValues*(self: var Cursor[byte], maxBytes = MaxValueBytes): PartialValue =
  template needs(n: Natural, msg: string) =
    if (self.pos + n) > self.buf.len:
      starved(msg)

  while self.buf.len > self.pos:
    let
      b = self.buf[self.pos]
      pk = b.partialKind
    case pk
    of pvNil, pvOpenFrame, pvCloseFrame:
      yield PartialValue(kind: pk, offset: self.pos)
      self.pos += 1
    of pvAtom:
      var len = b.headerData.inlineLen
      if len == 7:
        needs 2, "expected a length byte"
        len = int self.buf[self.pos + 1]
        guard len >= 7, "non minimal u8 length"
        if len == 255:
          needs 6, "expected 4 length bytes"
          len = 0
          for i in 2 .. 5:
            len = (len shl 8) or int self.buf[self.pos + i]
          guard len >= 255, "non minimal u32 length"
      guard len <= maxBytes, "scalar payload exceeds the value-size cap"
      let
        skip = uint32(len).skipLen
        total = skip + len
      needs total, "expected atom payload"

      let pv = PartialValue(kind: pvAtom, offset: self.pos, payloadLen: uint32(len))
      self.pos += total
      yield pv