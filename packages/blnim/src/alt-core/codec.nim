include pkg/prelude
import ./[types, rawvalues]
import std/strutils

const
  EndByte* = byte(0xA0)
  MaxPayloadSize* = uint32.high

type
  Writer* = concept w
    w.write(openArray[byte]) is int
  Reader* = concept r
    r.read(int) is openArray[byte]
    r.next() is (byte, bool)

# ================ READERS & WRITERS ================

proc write*[T](b: var T, bytes: openArray[byte]): int =
  b &= bytes
  result = bytes.len

proc read1(r: var Reader): byte =
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

proc readSize*(reader: var Reader, header: byte): int =
  result = int(header and 0b0111)
  if result == 7:
    result = int(reader.read1)
    if result < 7:
      refuse "size not minimal"
  if result == 255:
    result = int(largeSize(reader.read(4)))
    if result < 255:
      refuse "size not minimal"

proc readRaw*(
  reader: var Reader,
  header: byte,
  depth: int): RawValue =
  if depth <= 0:
    refuse "nesting past the depth limit"
  let size = reader.readSize(header)

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
      let h = reader.read1
      if h == EndByte:
        break
      els.add reader.readRaw(h, depth - 1)
    rawValue(els, header.kind, header.marked)

proc readRaw*(reader: var Reader, depth: int): RawValue =
  reader.readRaw(reader.read1, depth)

iterator rawValues*(reader: var Reader, maxDepth = 64): RawValue =
  mixin next
  while true:
    let (h, more) = reader.next()
    if not more:
      break
    yield reader.readRaw(h, maxDepth)

## ================ Streaming ================
type
  Fetch* = proc (buf: var openArray[byte]): int
  Stream* = object
    fetch: Fetch
    scratch: seq[byte]

func stream*(fetch: Fetch): Stream =
  Stream(fetch: fetch)

proc read*(r: var Stream, n: int): openArray[byte] =
  if r.scratch.len < n:
    r.scratch.setLen(n)
  var have = 0
  while have < n:
    let got = r.fetch(r.scratch.toOpenArray(have, n - 1))
    if got == 0:
      refuse "unexpected end of input"
    have += got
  result = r.scratch.toOpenArray(0, n - 1)

proc next*(r: var Stream): (byte, bool) =
  ## (next byte, is the fetcher still producing)
  var b: array[1, byte]
  if r.fetch(b) == 0: return (0, false)
  (b[0], true)

# ================ FETCHERS ================

func chunks*(data: sink seq[byte], cap = int.high): Fetch =
  ## an in-memory fetch; cap limits bytes per call, to mimic
  ## a source that trickles
  var data = data
  var pos = 0
  result = proc (buf: var openArray[byte]): int =
    result = min(min(buf.len, cap), data.len - pos)
    for i in 0 ..< result:
      buf[i] = data[pos + i]
    inc pos, result

func fileFetch*(f: File): Fetch =
  result = proc (buf: var openArray[byte]): int =
    f.readBytes(buf, 0, buf.len)

proc decodeRaw*(buf: sink seq[byte], maxDepth = 64): RawValue =
  var r = stream(chunks(buf))
  result = r.readRaw(maxDepth)
  if r.next()[1]:
    refuse "trailing bytes"

when isMainModule:
  import std/os

  var big = newSeq[byte](300)
  for i in 0 ..< big.len: big[i] = byte(i mod 251)

  let values = @[
    rawValue("hello from a file", bText),
    rawValue(@[rawValue("abc"), rawValue()], bList, marked = true),
    rawValue(big, bBytes)
  ]

  var buf: seq[byte]
  for v in values:
    discard buf.encode(v)
  let path = getTempDir() / "stream-demo.blb"
  writeFile(path, cast[string](buf))

  var r = stream(fileFetch(open(path)))
  var n = 0
  for v in r.rawValues:
    if v != values[n]:
      refuse "no match"
    inc n
  if n != values.len:
    refuse "stream ran dry early"

  removeFile(path)
  echo "streamed ", n, " values back off ", path