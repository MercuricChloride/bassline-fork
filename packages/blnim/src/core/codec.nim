{.experimental: "strictFuncs".}

import ./values

type
  DecodeError* = object of CatchableError
  PayloadSize = enum
    sm
    md
    lg

  InvalidPayloadSize* = object of CatchableError
  StreamDecoder* = object
    buf: seq[byte] # accumulated input
    start: int # first byte of the value currently being scanned
    scanPos: int # scan frontier (start <= scanPos <= buf.len)
    depth: int # frames open at the frontier
    skip: int # scalar payload bytes still to arrive
    maxDepth: int
    maxValueBytes: int

const
  EndByte = 0xA0
  MaxPayloadSize: uint32 = high(uint32)
  DefaultMaxValueBytes* = 150 * 1024 * 1024
  CompactThreshold = 64 * 1024
  ReleaseThreshold = 256 * 1024

# ================ DECODING ================

func fail(msg: string) {.noreturn.} =
  raise newException(DecodeError, msg)

func need(bytes: openArray[byte], pos, n: int) =
  if pos + n > bytes.len:
    fail "unexpected end of input"

func readLength(bytes: openArray[byte], pos: var int, lenBits: byte): int =
  case lenBits
  of 0 .. 6:
    int(lenBits)
  else: # 7: medium or large
    need(bytes, pos, 1)
    let medium = bytes[pos]
    inc pos
    case medium
    of 7 .. 254:
      int(medium)
    of 255:
      need(bytes, pos, 4)
      let len =
        (uint32(bytes[pos]) shl 24) or (uint32(bytes[pos + 1]) shl 16) or
        (uint32(bytes[pos + 2]) shl 8) or uint32(bytes[pos + 3])
      pos += 4
      if len < 255:
        fail "length in a longer form than its value requires"
      int(len)
    else: # 0 .. 6
      fail "length in a longer form than its value requires"

func decodeValue(bytes: openArray[byte], pos: var int, depth: int): Value =
  if depth <= 0:
    fail "nesting past the depth limit"
  need(bytes, pos, 1)
  let header = bytes[pos]
  inc pos
  let
    tag = header shr 4
    marked = (header and 0b1000) != 0
    lenBits = header and 0b0111

  case tag
  of 0x1:
    if lenBits != 0:
      fail "null with nonzero length bits"
    nilValue(marked)
  of 0x2 .. 0x5:
    let
      len = readLength(bytes, pos, lenBits)
      t: 0x2 .. 0x5 = tag
      start = pos
      stop = pos + len
    need(bytes, pos, len)
    pos += len
    case t
    of 0x2:
      try:
        num(toString(bytes[start ..< stop]), marked)
      except InvalidDecStr:
        fail "integer payload isn't canonical decimal notation"
    of 0x3:
      try:
        text(toValidUtf8(bytes[start ..< stop]), marked)
      except InvalidUtf8Str:
        fail "Text payload malformed"
    of 0x4:
      try:
        sym(toValidUtf8(bytes[start ..< stop]), marked)
      except InvalidUtf8Str:
        fail "Symbol payload malformed"
    of 0x5:
      values.bytes(bytes[start ..< stop], marked)
  of 0x6 .. 0x9:
    if lenBits != 0:
      fail "frame header with nonzero length bits"
    var children: seq[Value]
    let t: 0x6 .. 0x9 = tag
    while true:
      need(bytes, pos, 1)
      if bytes[pos] == EndByte:
        inc pos
        break
      children.add decodeValue(bytes, pos, depth - 1)
    case t
    of 0x6:
      list(children, marked)
    of 0x7:
      if children.len == 0:
        fail "record with no head"
      record(children).mark(marked)
    of 0x8:
      if children.len mod 2 != 0:
        fail "dict with a key missing its value"
      var entries = newSeqOfCap[Entry](pairCount(children.len))
      for p in pairIndex(children):
        entries.add (children[p.key], children[p.val])
      for p in pairIndex(entries):
        if p == 0: continue
        if cmp(entries[p.prev].key, entries[p].key) >= 0:
          fail "dict keys out of order or duplicated"
      dict(entries).mark(marked)
    of 0x9:
      for s in slotIndex(children):
        if s == 0: continue
        if cmp(children[s.prev], children[s]) >= 0:
          fail "set members out of order or duplicated"
      set(children).mark(marked)
  of 0xA:
    if header == EndByte:
      fail "END where a value was expected"
    fail "END carries no flag and no length"
  else:
    fail "invalid tag"

func decode*(bytes: openArray[byte], maxDepth = 64): Value =
  var pos = 0
  result = decodeValue(bytes, pos, maxDepth)
  if pos != bytes.len:
    fail "trailing bytes after value"

func decode*(str: string, maxDepth = 64): Value =
  decode(str.toBytes, maxDepth)

# ================ ENCODING ================

func payloadSize(len: int): PayloadSize =
  case len
  of 0 .. 6:
    sm
  of 7 .. 254:
    md
  else:
    if len <= int(MaxPayloadSize):
      lg
    else:
      raise newException(InvalidPayloadSize, "payload too large: " & $len)

func write*(buf: var seq[byte], b: byte) =
  buf.add b

func write*(buf: var seq[byte], bytes: openArray[byte]) =
  if bytes.len > 0:
    let start = buf.len
    buf.setLen(start + bytes.len)
    copyMem(addr buf[start], addr bytes[0], bytes.len)

func write*(w: var string, b: byte) =
  w.add char(b)

func write*(w: var string, bytes: openArray[byte]) =
  if bytes.len > 0:
    let start = w.len
    w.setLen(start + bytes.len)
    copyMem(addr w[start], addr bytes[0], bytes.len)

func encodeInto*[W](value: Value, w: var W) =
  ## Writes the CE bytes of `value` to any writer providing
  ## `write(var W, byte)` and `write(var W, openArray[byte])`.
  let
    len = value.payloadLength
    hTag = byte(value.tag) shl 4
    hMark = byte(value.marked) shl 3
    hLen = byte(min(len, 7)) # 7 being last 3 bits hi 111

  # the first byte is [tag:4][mark:1][len:3]
  w.write byte(hTag or hMark or hLen)

  # then comes the length byte(s) if any
  case payloadSize(len)
  of sm:
    discard
  of md:
    # medium sizes fit into a single byte
    w.write byte(len)
  of lg:
    # large sizes have their medium byte maxed out
    w.write byte(0xFF)
    # followed by a 4 byte big endian length
    w.write byte((len shr 24) and 0xFF)
    w.write byte((len shr 16) and 0xFF)
    w.write byte((len shr 8) and 0xFF)
    w.write byte(len and 0xFF)

  case value.kind
  of bNil:
    discard
  of bNum:
    let s = string(value.num)
    w.write s.toOpenArrayByte(0, s.high)
  of bText, bSym:
    let s = string(value.text)
    w.write s.toOpenArrayByte(0, s.high)
  of bBytes:
    w.write value.bytes
  of bList:
    for item in value.children:
      item.encodeInto w
    w.write EndByte
  of bRecord:
    for item in value.children:
      item.encodeInto w
    w.write EndByte
  of bSet:
    for el in value.children:
      el.encodeInto w
    w.write EndByte
  of bDict:
    for el in value.children:
      el.encodeInto w
    w.write EndByte

func encode*(x: Value): seq[byte] =
  encodeInto(x, result)

func encodeToString*(x: Value): string =
  encodeInto(x, result)

# ================ STREAMING ================

func checkSize(sd: StreamDecoder, declared: int) =
  if (sd.scanPos - sd.start) + declared > sd.maxValueBytes:
    fail "value exceeds the size limit"

func skipPayload(sd: var StreamDecoder, payload: int): bool =
  ## Advances over scalar payload bytes, as many as have arrived.
  ## Returns false when the rest of the payload is still in flight.
  let n = min(sd.buf.len - sd.scanPos, payload)
  sd.scanPos += n
  sd.skip = payload - n
  sd.skip == 0

func scan(sd: var StreamDecoder): bool =
  ## Advances the frontier. True when buf[start ..< scanPos] spans one
  ## complete value. False means more bytes are needed; scanner state
  ## is kept so the next call resumes where this one stopped.
  while true:
    if sd.skip > 0:
      if not sd.skipPayload(sd.skip):
        return false
      if sd.depth == 0:
        return true
    if sd.scanPos >= sd.buf.len:
      return false
    let
      header = sd.buf[sd.scanPos]
      tag = header shr 4
      lenBits = header and 0b0111

    case tag
    of 0x1:
      # nil declares no payload; nonzero length bits are for decode to
      # reject, and it consumes only the header byte before doing so
      inc sd.scanPos
      if sd.depth == 0:
        return true
    of 0x2 .. 0x5:
      var
        hdrLen = 1
        payload = int(lenBits)
      if lenBits == 7:
        let avail = sd.buf.len - sd.scanPos
        if avail < 2:
          return false
        let medium = sd.buf[sd.scanPos + 1]
        if medium == 255:
          if avail < 6:
            return false
          payload = int(
            (uint32(sd.buf[sd.scanPos + 2]) shl 24) or
              (uint32(sd.buf[sd.scanPos + 3]) shl 16) or
              (uint32(sd.buf[sd.scanPos + 4]) shl 8) or uint32(sd.buf[sd.scanPos + 5])
          )
          hdrLen = 6
        else:
          payload = int(medium)
          hdrLen = 2
      # reject a declared size over the limit before buffering any of it
      sd.checkSize(hdrLen + payload)
      sd.scanPos += hdrLen
      if not sd.skipPayload(payload):
        return false
      if sd.depth == 0:
        return true
    of 0x6 .. 0x9:
      # decidable at this byte, so don't buffer a doomed stream
      # waiting for decode's verdict
      if lenBits != 0:
        fail "frame header with nonzero length bits"
      inc sd.depth
      if sd.depth > sd.maxDepth:
        fail "nesting past the depth limit"
      inc sd.scanPos
    of 0xA:
      if header != EndByte:
        fail "END carries no flag and no length"
      if sd.depth == 0:
        fail "END where a value was expected"
      dec sd.depth
      inc sd.scanPos
      if sd.depth == 0:
        return true
    else:
      fail "invalid tag"

func compact(sd: var StreamDecoder) =
  if sd.start == sd.buf.len:
    if sd.buf.len >= ReleaseThreshold:
      # setLen never shrinks capacity; don't let one big value pin
      # its peak allocation for the connection's lifetime
      sd.buf = @[]
    else:
      sd.buf.setLen(0)
    sd.start = 0
    sd.scanPos = 0
  elif sd.start >= CompactThreshold:
    let remaining = sd.buf.len - sd.start
    moveMem(addr sd.buf[0], addr sd.buf[sd.start], remaining)
    sd.buf.setLen(remaining)
    sd.scanPos -= sd.start
    sd.start = 0

func initStreamDecoder*(
    maxDepth = 64, maxValueBytes = DefaultMaxValueBytes
): StreamDecoder =
  StreamDecoder(maxDepth: maxDepth, maxValueBytes: maxValueBytes)

func buffered*(sd: StreamDecoder): int =
  ## Bytes received but not yet returned as a value.
  sd.buf.len - sd.start

func feed*(sd: var StreamDecoder, data: openArray[byte]) =
  sd.buf.add data

func next*(sd: var StreamDecoder): Option[Value] =
  ## The next complete value, or none until more bytes are fed.
  ## Raises DecodeError on malformed input or a breached limit.
  if sd.scan():
    # the limit binds on the value itself, however it arrived
    # header-only bytes (frames, nils, ENDs) declare no sizes, so a
    # completed span is the first place their total is knowable
    sd.checkSize(0)
    let value = decode(sd.buf.toOpenArray(sd.start, sd.scanPos - 1), sd.maxDepth)
    sd.start = sd.scanPos
    sd.compact()
    some value
  else:
    # an incomplete value may wait forever, but never past the limit
    sd.checkSize(0)
    none Value
