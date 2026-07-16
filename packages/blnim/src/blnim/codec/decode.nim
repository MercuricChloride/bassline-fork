{.experimental: "strictFuncs".}

import ../values
export values

type 
  DecodeError* = object of CatchableError

func fail(msg: string) {.noreturn.} =
  raise newException(DecodeError, msg)

func need(bytes: openArray[byte]; pos, n: int) =
  if pos + n > bytes.len:
    fail "unexpected end of input"

func readLength(bytes: openArray[byte]; pos: var int; lenBits: byte): int =
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
      let len = (uint32(bytes[pos]) shl 24) or
                (uint32(bytes[pos + 1]) shl 16) or
                (uint32(bytes[pos + 2]) shl 8) or
                 uint32(bytes[pos + 3])
      pos += 4
      if len < 255:
        fail "length in a longer form than its value requires"
      int(len)
    else: # 0 .. 6
      fail "length in a longer form than its value requires"

func decodeValue(bytes: openArray[byte]; pos: var int; depth: int): Value =
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
      if bytes[pos] == END_BYTE:
        inc pos
        break
      children.add decodeValue(bytes, pos, depth - 1)
    case t
    of 0x6:
      list(children, marked)
    of 0x7:
      if children.len == 0:
        fail "record with no head"
      record(children, marked)
    of 0x8:
      if children.len mod 2 != 0:
        fail "dict with a key missing its value"
      var entries = newSeqOfCap[(Value, Value)](children.len div 2)
      for i in countup(0, children.len - 1, 2):
        entries.add (children[i], children[i + 1])
      for i in 1 ..< entries.len:
        if cmp(entries[i - 1][0], entries[i][0]) >= 0:
          fail "dict keys out of order or duplicated"
      dict(entries, marked)
    of 0x9:
      for i in 1 ..< children.len:
        if cmp(children[i - 1], children[i]) >= 0:
          fail "set members out of order or duplicated"
      set(children, marked)

  of 0xA:
    if header == END_BYTE:
      fail "END where a value was expected"
    fail "END carries no flag and no length"

  else:
    fail "invalid tag"

func decode*(bytes: openArray[byte]; maxDepth = 64): Value =
  var pos = 0
  result = decodeValue(bytes, pos, maxDepth)
  if pos != bytes.len:
    fail "trailing bytes after value"
