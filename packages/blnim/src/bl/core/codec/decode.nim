import ./shared

# ================ Decoded Values ================

type
  ValueView* = ref object
    buf: Buffer[byte]
    offset*, len*: int
    parent* {.cursor.}: ValueView
    validated: bool
    case kind*: Kind
    of bNil: discard
    of bNum..bBytes:
      payloadLen: uint32
    of bList, bRec, bSet:
      children: seq[ValueView]
    of bDict:
      entries: seq[Entry]
  Entry = tuple[key, val: ValueView]

  Callback = proc(val: ValueView)

func children*(self: ValueView): lent seq[ValueView] =
  return self.children

func entries*(self: ValueView): lent seq[Entry] =
  return self.entries

func payloadLen*(self: ValueView): uint32 =
  self.payloadLen

func headerData*(self: ValueView): HeaderData =
  headerData self.buf.data[self.offset]

func mark*(self: ValueView): bool =
  self.headerData.mark

func span*(self: ValueView): tuple[lo, hi: int] =
  (lo: self.offset, hi: self.offset + self.len - 1)

func validated*(self: ValueView): bool =
  self.validated

template bytes*(self: ValueView): openArray[byte] =
  let (lo, hi) = self.span
  self.buf.data.toOpenArray(lo, hi)

template payloadBytes*(self: ValueView): openArray[byte] =
  let (lo, hi) = self.span
  self.buf.data.toOpenArray(lo + self.payloadLen.skipLen, hi)

func cmp*(a, b: ValueView): int =
  cmpBytes(a.bytes, b.bytes)

func `==`*(a, b: ValueView): bool =
  if a.isNil and b.isNil: 
    return true
  if a.isNil or b.isNil: 
    return false
  cmp(a, b) == 0

func `<`*(a, b: ValueView): bool =
  cmp(a, b) < 0

proc validate*(self: ValueView)

proc validate*(self: Entry) =
  validate self.key
  validate self.val

proc validate(vals: openArray[ValueView]) =
  for val in vals:
    validate val

proc validate*(self: ValueView) =
  template ok() =
    self.validated = true
    return

  if self.validated: return

  case self.kind
  of bNil, bBytes: discard
  of bNum:
    guard isValidInt self.payloadBytes, "malformed number"
  of bText, bSym:
    guard isValidUtf8 self.payloadBytes, "invalid utf8 bytes"
  of bDict:
    var prev {.cursor.}: Entry
    for i, e in self.entries:
      guard e.val != nil, "dict cannot have stranded keys"
      validate e
      if i > 0:
        guard prev.key < e.key, "dict keys must be strictly ascending"
      prev = e
  of bSet:
    var prev {.cursor.}: ValueView
    for i, child in self.children:
      validate child
      if i > 0:
        guard prev < child, "set elements must be strictly ascending"
      prev = child
  of bRec:
    guard self.children.len > 0, "records cannot be empty"
    validate self.children
  of bList:
    validate self.children
  ok

func root*(self: ValueView): ValueView =
  var r {.cursor.} = self
  while r.parent != nil:
    r = r.parent
  return r

proc childrenDo*(self: ValueView, cb: Callback, deep = false) =
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

# ================ Decoder ================

type Decoder* = object
    cursor: Cursor[byte]
    frames: seq[ValueView]
    pending: bool

proc newDecoder*(buf: Buffer[byte] = newBuffer[byte]()): Decoder =
  Decoder(cursor: buf.initCursor(), frames: newSeqOfCap[ValueView](MaxDepth))

func pending*(self: Decoder): bool =
  self.pending

func buf*(self: Decoder): Buffer[byte] =
  self.cursor.buf

proc toValue(pv: PartialValue, buf: Buffer[byte]): ValueView =
    let 
      h = headerData buf.data[pv.offset]
      k = h.kind
    case k
    of bNil:
      ValueView(kind: k, len: 1, buf: buf, offset: pv.offset)
    of bNum..bBytes:
      let len = pv.payloadLen.skipLen + int(pv.payloadLen)
      ValueView(kind: k, len: len, buf: buf, offset: pv.offset, payloadLen: pv.payloadLen)
    of bList, bRec, bSet:
      ValueView(kind: k, buf: buf, offset: pv.offset, children: @[])
    of bDict:
      ValueView(kind: k, buf: buf, offset: pv.offset, entries: @[])

iterator items*(self: var Decoder, shouldValidate = true): ValueView =

  template maybeYield(v: ValueView) =
    if self.frames.len == 0:
      if shouldValidate:
        validate v
      self.pending = false
      yield v
    else:
      let frame = self.frames[^1]
      v.parent = frame
      if frame.kind != bDict:
        frame.children.add v
      else:
        if frame.entries.len > 0 and
          frame.entries[^1].val.isNil:
            frame.entries[^1].val = v
        else:
          frame.entries.add (key: v, val: nil)

  try:
    for part in self.cursor.partialValues:
      case part.kind
      of pvNil:
        let v = part.toValue(self.buf)
        maybeYield v
      of pvAtom:
        let v = part.toValue(self.buf)
        maybeYield v
      of pvOpenFrame:
        guard self.frames.len < MaxDepth, "max frame depth exceeded"
        self.frames.add part.toValue(self.buf)
        self.pending = true
      of pvCloseFrame:
        guard self.frames.len > 0, "unexpected END with no frames on stack"
        
        let f = self.frames.pop
        f.len = part.offset + 1 - f.offset
        maybeYield f

  except BufferStarvedError:
    self.pending = true

iterator checked*(self: var Decoder): ValueView =
  for val in self.items(true): 
    yield val

iterator unchecked*(self: var Decoder): ValueView =
  for val in self.items(false): 
    yield val

template bytes*(self: Decoder): openArray[byte] =
  self.buf.bytes