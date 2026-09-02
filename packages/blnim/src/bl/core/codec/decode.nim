import ./shared

# ================ Decoded Values ================

type
  DecodedValue* = ref object
    buf*: Buffer
    offset*, len*: int
    parent*: DecodedValue
    validated: bool
    case kind*: Kind
    of bNil: discard
    of bNum..bBytes:
      payloadLen: uint32
    of bList, bRec, bSet:
      children: seq[DecodedValue]
    of bDict:
      entries: seq[Entry]

  Entry = tuple[key, val: DecodedValue]


  Callback = proc(val: DecodedValue)

func children*(self: DecodedValue): lent seq[DecodedValue] =
  return self.children

func entries*(self: DecodedValue): lent seq[Entry] =
  return self.entries

func payloadLen*(self: DecodedValue): uint32 =
  self.payloadLen

func headerData*(self: DecodedValue): HeaderData =
  headerData self.buf.data[self.offset]

func mark*(self: DecodedValue): bool =
  self.headerData.mark

func span*(self: DecodedValue): tuple[lo, hi: int] =
  (lo: self.offset, hi: self.offset + self.len - 1)

func validated*(self: DecodedValue): bool =
  self.validated

template toOpenArray*(self: DecodedValue): openArray[byte] =
  let (lo, hi) = self.span
  self.buf.data.toOpenArray(lo, hi)

template payloadBytes*(self: DecodedValue): openArray[byte] =
  let (lo, hi) = self.span
  self.buf.data.toOpenArray(lo + self.payloadLen.skipLen, hi)

func cmp*(a, b: DecodedValue): int =
  cmpBytes(a.toOpenArray, b.toOpenArray)

func `==`*(a, b: DecodedValue): bool =
  cmp(a, b) == 0

func `<`*(a, b: DecodedValue): bool =
  cmp(a, b) < 0

func root*(self: DecodedValue): DecodedValue =
  var r {.cursor.} = self
  while r.parent != nil:
    r = r.parent
  return r

proc childrenDo(self: DecodedValue, cb: Callback, deep = false) =
  template recur(val) =
    cb(val)
    if deep:
      val.childrenDo(cb, deep = true)
  case self.kind
  of bDict:
    for (key, val) in self.entries:
      recur key
      recur val
  of bList, bRec, bSet:
    for child in self.children:
      recur child
  else: discard

proc validate*(self: DecodedValue) =
  template ok() =
    self.validated = true
    return

  if self.validated: return

  case self.kind
  of bNum:
    guard isValidInt self.payloadBytes, "malformed number"
  of bText, bSym:
    guard isValidUtf8 self.payloadBytes, "invalid utf8 bytes"
  of bDict:
    for (key, val) in self.entries:
      validate key
      validate val
  of bList, bRec, bSet:
    for child in self.children:
      validate child
  else: discard
  ok

# ================ Decoder ================

type 
  Decoder* = ref object
    buf: Buffer
    frames: seq[DecodedValue]

proc newDecoder*(buf: Buffer = newBuffer()): Decoder =
  Decoder(buf: buf, frames: @[])

iterator items*(self: Decoder, shouldValidate = true): DecodedValue =

  template toValue(pv: PartialValue): DecodedValue =
    let 
      h = headerData self.buf.data[pv.offset]
      k = h.kind
    case k
    of bNil:
      DecodedValue(kind: k, len: 1, buf: self.buf, offset: pv.offset)
    of bNum..bBytes:
      let len = pv.payloadLen.skipLen + int(pv.payloadLen)
      DecodedValue(kind: k, len: len, buf: self.buf, offset: pv.offset, payloadLen: pv.payloadLen)
    of bList, bRec, bSet:
      DecodedValue(kind: k, buf: self.buf, offset: pv.offset, children: @[])
    of bDict:
      DecodedValue(kind: k, buf: self.buf, offset: pv.offset, entries: @[])

  template maybeYield(v: DecodedValue) =
    if self.frames.len == 0:
      if shouldValidate:
        validate v
      yield v
    else:
      let frame = self.frames[^1]
      v.parent = frame
      if frame.kind != bDict:
        frame.children.add v
      else:
        if frame.entries.len == 0 or
          frame.entries[^1].val != nil:
          frame.entries.add (key: v, val: nil)
        else:
          frame.entries[^1].val = v
  
  try:
    for part in self.buf.partialValues:
      case part.kind
      of pvNil:
        maybeYield part.toValue
      of pvAtom:
        maybeYield part.toValue
      of pvOpenFrame:
        self.frames.add part.toValue
      of pvCloseFrame:
        let f = self.frames.pop
        f.len = part.offset - f.offset
        block validation:
          case f.kind
          of bRec:
            guard f.children.len > 0, "records cannot be empty"
          of bSet:
            if f.children.len == 0:
              break validation
            for i in 1..f.children.high:
              let
                a = f.children[i - 1]
                b = f.children[i]
              guard a < b, "set elements must be strictly ascending"
          of bDict:
            if f.entries.len == 0:
              break validation
            guard f.entries[^1].val != nil, "dicts cannot have stranded keys"
            for i in 1..f.entries.high:
              let
                a = f.entries[i - 1]
                b = f.entries[i]
              guard a.key < b.key, "dict keys must be strictly ascending"
          else: discard
        maybeYield f
  except BufferStarvedError:
    discard

iterator checked*(self: Decoder): DecodedValue =
  for val in self.items(true): 
    yield val

iterator unchecked*(self: Decoder): DecodedValue =
  for val in self.items(false): 
    yield val