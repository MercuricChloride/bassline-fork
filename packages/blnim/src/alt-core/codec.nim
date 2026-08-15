include pkg/prelude
import ./[types, rawvalues]
import std/strutils

const
  EndByte* = byte(0xA0)
  MaxPayloadSize* = uint32.high

# ================ READERS & WRITERS ================

type
  Writer* = concept w
    w.write(openArray[byte]) is int

  Reader* = concept r
    r.need(int)
    r.peek() is byte
    r.read(int) is openArray[byte]
  
  Decoder* = object
    buf: seq[byte]
    pos: int

proc write*[T](b: var T, bytes: openArray[byte]): int =
  b &= bytes
  result = bytes.len

func need(d: Decoder, n: int) =
  if d.pos + (n - 1) > d.buf.high:
    refuse "unexpected end of input"
func read(d: var Decoder, n: int): openArray[byte] =
  d.need(n)
  result = d.buf.toOpenArray(d.pos, d.pos + n - 1)
  inc(d.pos, n)
func peek(d: Decoder): byte =
  d.need(1)
  d.buf[d.pos]

func read(r: var Reader): byte =
  r.read(1)[0]

# ================ ENCODING ================

func header*(v: Value): byte =
  byte(v.tag) shl 4 or
  byte(v.marked) shl 3 or
  byte(min(v.size, 7))

func largeSize*(b: openArray[byte], offset: int = 0): uint32 =
  if 3 + offset > b.high:
    refuse "large bytes needs 4 bytes"
  (uint32(b[offset]) shl 24) or
  (uint32(b[offset + 1]) shl 16) or
  (uint32(b[offset + 2]) shl 8) or
  (uint32(b[offset + 3]))

func largeSize*(size: uint32): array[4, byte] =
  [ (byte(size shr 24) and 0xFF),
    (byte(size shr 16) and 0xFF),
    (byte(size shr 8) and 0xFF),
    (byte(size) and 0xFF) ]

proc encodeSize(e: var Writer, v: Value): int =
  if v.kind notin SizedKinds:
    refuse "encodeSize: kind doesnt have a payload"
  case v.size:
  of 0..6: 
    # the size is already in the header bits
    discard
  of 7..254:
    result = e.write [byte(v.size)]
  of 255..int(MaxPayloadSize):
    result += e.write [byte(0xFF)]
    result += e.write largeSize(uint32(v.size))
  else:
    refuse "encodeSize: invalid size"

proc encode*(enc: var Writer, v: Value): int =
  result += enc.write([v.header])
  if v.kind == bNil: discard
  elif v.kind in AtomKinds:
    result += enc.encodeSize(v)
    result += enc.write(v.payload)
  else:
    for el in v.els:
      result += enc.encode(el)
    result += enc.write([EndByte])

# ================ DECODING ================

func kind*(b: byte): BlKind =
  let tag = (byte(b) shr 4)
  if tag == 0:
    refuse "kind: 0 is not a valid tag"
  BlKind(tag - 1)

func marked*(b: byte): bool =
  (byte(b) and 0b1000) != 0

func readSize*(reader: var Reader, header: byte): int =
  result = int(header and 0b0111)
  if result == 7:
    result = int(reader.read())
    if result < 7:
      refuse "size not minimal"
  if result == 255:
    result = int(largeSize(reader.read(4)))
    if result < 255:
      refuse "size not minimal"

func readRaw*(
  reader: var Reader,
  depth: int): RawValue =
  if depth <= 0:
    refuse "nesting past the depth limit"
  let
    header = reader.read()
    size = reader.readSize(header)

  case header.kind
  of bNil:
    if size != 0:
      refuse "nil with nonzero size"
    rawValue(marked = header.marked)
  of bNum..bBytes:
    let payload = @(reader.read(size))
    rawValue(payload, header.kind, header.marked)
  of bList..bSet:  
    if size != 0:
      refuse "frame with nonzero size"
    var els: seq[RawValue]
    while true:
      if reader.peek() == EndByte:
        discard reader.read()
        break
      els.add reader.readRaw(depth - 1)
    rawValue(els, header.kind, header.marked)

func decodeRaw*(buf: sink seq[byte], maxDepth = 64): RawValue =
  var d = Decoder(buf: buf, pos: 0)
  result = d.readRaw(maxDepth)
  if d.pos != d.buf.len:
    refuse "trailing bytes"