include pkg/prelude
import ./[types, macros]

const
  EndByte* = byte(0xA0)
  MaxPayloadSize* = uint32.high

type
  Writer* = concept
    proc write(s: Self, b: openArray[byte]): int
  Reader* = concept
    proc read(s: Self, n: int): openArray[byte]
    proc next(s: Self): (byte, bool)

# ================ READERS & WRITERS ================

proc write*[T](b: var T, bytes: openArray[byte]): int =
  b &= bytes
  result = bytes.len

proc read1(r: var Reader): byte =
  r.read(1)[0]

# ================ ENCODING ================

proc header*(v: Value): byte =
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

proc readValue*[V: Builder](
  reader: var Reader,
  header: byte,
  depth: int): V =
  if depth <= 0:
    refuse "nesting past the depth limit"
  let size = reader.readSize(header)

  case header.kind
  of bNil:
    if size != 0:
      refuse "nil with nonzero size"
    null[V](header.marked)
  of bNum..bBytes:
    atom[V](reader.read(size), header.kind, header.marked)
  of bList..bSet:
    if size != 0:
      refuse "frame with nonzero size"
    var els: seq[V]
    while true:
      let h = reader.read1
      if h == EndByte:
        break
      els.add readValue[V](reader, h, depth - 1)
    frame[V](els, header.kind, header.marked)

proc readValue*[V: Value](reader: var Reader, depth: int): V =
  readValue[V](reader, reader.read1, depth)

iterator readValues*[V: Value](reader: var Reader, maxDepth = 64): V =
  while true:
    let (h, more) = reader.next()
    if not more:
      break
    yield readValue[V](reader, h, maxDepth)

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

proc decode*[V: Value](buf: sink seq[byte], maxDepth = 64): V =
  var r = stream(chunks(buf))
  result = readValue[V](r, maxDepth)
  if r.next()[1]:
    refuse "trailing bytes"

when isMainModule:
  import std/[os, tables]
  import ./rawvalues, digest

  var big = newSeq[byte](300_000)
  for i in 0 ..< big.len: big[i] = byte(i mod 251)

  type
    BlakeHash = array[32, byte]

  type
    Store = ref object
      payloads: Table[BlakeHash, seq[byte]]
      els: Table[BlakeHash, seq[Digested]]
    Digested = object
      store: Store
      key: BlakeHash
      kind: BlKind
      marked: bool

  var store = Store()

  Digested.defvalue:
    atom(payload, kind, marked):
      let key = blake2b(payload)
      if key notin store.payloads:
        store.payloads[key] = @payload
      Digested(store: store, key: key, kind: kind, marked: marked)
    frame(els, kind, marked):
      let key = blake2b(els)
      if key notin store.els:
        store.els[key] = els
      Digested(store: store, key: key, kind: kind, marked: marked)
    null(marked):
      Digested(marked: marked)
    size(self):
      if self.kind in SizedKinds:
        self.store.payloads[self.key].len
      else: 0
    payload(self):
      if self.kind notin SizedKinds:
        refuse "not an atom with a payload"
      return self.store.payloads[self.key]
    els(self):
      if self.kind notin FrameKinds:
        refuse "not a frame"
      return self.store.els[self.key]

  let values: seq[RawValue] = @[
    atom[RawValue]("hello from a file"),
    frame(@[atom[RawValue]("abc"), null[RawValue]()], bList, true),
    atom[RawValue](big, bBytes)
  ]

  var buf: seq[byte]
  for _ in 1 .. 100:
    for v in values:
      discard buf.encode(v)
  let path = getTempDir() / "stream-demo.blb"
  removeFile(path)
  writeFile(path, cast[string](buf))

  var r = stream(fileFetch(open(path)))
  var n = 0
  for v in readValues[Digested](r):
    if n == 0:
      echo "raw == raw: ", values[0] == values[0]
      echo "digested == digested: ", v == v
      echo "digested == raw: ", v == values[0]
    inc n
  if n != values.len * 100:
    refuse "stream ran dry early"
  echo "unique payloads stored: ", store.payloads.len
  echo "unique child-seqs stored: ", store.els.len
  echo "streamed ", n, " values back off ", path