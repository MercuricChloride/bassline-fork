{.experimental: "strictFuncs".}

## Streaming decoder for a connection carrying a bare concatenation of
## CE-encoded values.
##
## Works by scanning for the boundary of the next complete top-level
## value, then handing the exact slice to the strict batch
## decoder. The scanner only mirrors the framing rules; `decode` stays
## the sole validation authority. Any disagreement between the two
## ends with the slice rejected and is always fatal. On DecodeError
## the decoder is dead and should be discarded and cleaned up.

import std/options
import decode
export options, decode

const
  DefaultMaxValueBytes* = 150 * 1024 * 1024
  CompactThreshold = 64 * 1024
  ReleaseThreshold = 256 * 1024

type StreamDecoder* = object
  buf: seq[byte] # accumulated input
  start: int # first byte of the value currently being scanned
  scanPos: int # scan frontier (start <= scanPos <= buf.len)
  depth: int # frames open at the frontier
  skip: int # scalar payload bytes still to arrive
  maxDepth: int
  maxValueBytes: int

func fail(msg: string) {.noreturn.} =
  raise newException(DecodeError, msg)

func initStreamDecoder*(
    maxDepth = 64, maxValueBytes = DefaultMaxValueBytes
): StreamDecoder =
  StreamDecoder(maxDepth: maxDepth, maxValueBytes: maxValueBytes)

func buffered*(sd: StreamDecoder): int =
  ## Bytes received but not yet returned as a value.
  sd.buf.len - sd.start

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
      if header != END_BYTE:
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
