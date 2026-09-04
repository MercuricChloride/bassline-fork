import ./shared

type
  Encoder* = ref object
    buf*: Buffer[byte]
    depth: Natural

proc newEncoder*(buf: Buffer[byte] = newBuffer[byte]()): Encoder =
  Encoder(buf: buf)

proc putRaw*(e: Encoder, data: openArray[byte]) =
  e.buf.data.add data

proc putHeader(e: Encoder, kind: Kind, mark: bool, len: int) =
  case kind
  of bNum:
    guard len > 0, "num cannot have a length of 0"
  of bNil, bList, bRec, bDict, bSet:
    guard len == 0, "invalid len for kind: " & $kind
  else: discard

  let
    k: byte = kind.tag
    m: byte = if mark: MarkBit else: 0
    l: byte = byte min(len, 7)
    h: byte = ((k shl 4) or m or l)

  e.buf.data.add h

  if len in 7..254:
    e.buf.data.add byte len
  elif len >= 255:
    e.buf.data.add 0xFF
    for shift in [24, 16, 8, 0]:
      e.buf.data.add byte((len shr shift) and 0xFF)

proc putScalar*(e: Encoder, kind: Kind, mark: bool, payload: openArray[byte] = []) =
  guard kind in bNil..bBytes, "not a scalar kind"
  guard payload.len <= MaxPayload.int, "payload too large"
  e.putHeader(kind, mark, payload.len)
  e.buf.data.add payload

proc putOpen*(e: Encoder, kind: Kind, mark: bool) =
  guard kind in bList..bSet, "not a frame kind"
  guard e.depth < MaxDepth, "max frame depth exceeded"
  inc e.depth
  e.putHeader(kind, mark, 0)

proc putClose*(e: Encoder) =
  guard e.depth > 0, "unxpected END with no frame to close"
  dec e.depth
  e.buf.data.add EndByte

func pending*(e: Encoder): bool =
  e.depth > 0

func ready*(e: Encoder): bool =
  not e.pending

template bytes*(e: Encoder): openArray[byte] =
  guard e.ready, "encoder still pending"
  e.buf.bytes

template frame*(e: Encoder, kind: Kind, mark: bool, body: untyped) =
  e.putOpen(kind, mark)
  body
  e.putClose()

template frame*(e: Encoder, kind: Kind, body: untyped) =
  e.putOpen(kind, false)
  body
  e.putClose()