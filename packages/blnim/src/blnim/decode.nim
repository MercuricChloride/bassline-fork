{.experimental: "strictFuncs".}

import values

export values

type DecodeError* = object of CatchableError

func fail(msg: string) {.noreturn.} =
  raise newException(DecodeError, msg)

func need(bytes: openArray[byte]; pos, n: int) =
  if pos + n > bytes.len:
    fail "unexpected end of input"

func isCont(b: byte): bool =
  (b and 0xC0) == 0x80

func isValidUtf8(s: openArray[byte]): bool =
  ## Unicode Table 3-7 well-formedness. Rejects overlong forms,
  ## surrogates, and anything past U+10FFFF, which std/unicode's
  ## validateUtf8 accepts (nim-lang/Nim#19333).
  var i = 0
  while i < s.len:
    case s[i]
    of 0x00 .. 0x7F:
      inc i
    of 0xC2 .. 0xDF:
      if i + 1 >= s.len or not isCont(s[i + 1]):
        return false
      i += 2
    of 0xE0:
      if i + 2 >= s.len or s[i + 1] notin 0xA0'u8 .. 0xBF'u8 or not isCont(s[i + 2]):
        return false
      i += 3
    of 0xE1 .. 0xEC, 0xEE .. 0xEF:
      if i + 2 >= s.len or not isCont(s[i + 1]) or not isCont(s[i + 2]):
        return false
      i += 3
    of 0xED:
      if i + 2 >= s.len or s[i + 1] notin 0x80'u8 .. 0x9F'u8 or not isCont(s[i + 2]):
        return false
      i += 3
    of 0xF0:
      if i + 3 >= s.len or s[i + 1] notin 0x90'u8 .. 0xBF'u8 or
          not isCont(s[i + 2]) or not isCont(s[i + 3]):
        return false
      i += 4
    of 0xF1 .. 0xF3:
      if i + 3 >= s.len or not isCont(s[i + 1]) or
          not isCont(s[i + 2]) or not isCont(s[i + 3]):
        return false
      i += 4
    of 0xF4:
      if i + 3 >= s.len or s[i + 1] notin 0x80'u8 .. 0x8F'u8 or
          not isCont(s[i + 2]) or not isCont(s[i + 3]):
        return false
      i += 4
    else:
      return false
  true

func toString(s: openArray[byte]): string =
  result = newString(s.len)
  for i in 0 ..< s.len:
    result[i] = char(s[i])

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
    let len = readLength(bytes, pos, lenBits)
    need(bytes, pos, len)
    let payload = bytes[pos ..< pos + len]
    pos += len
    case tag
    of 0x2:
      try:
        num(toString(payload), marked)
      except InvalidDecStr:
        fail "integer payload isn't canonical decimal notation"
    of 0x3, 0x4:
      if not isValidUtf8(payload):
        fail "ill-formed UTF-8"
      if tag == 0x3:
        text(toString(payload), marked)
      else:
        sym(toString(payload), marked)
    else:
      values.bytes(payload, marked)

  of 0x6 .. 0x9:
    if lenBits != 0:
      fail "frame header with nonzero length bits"
    var children: seq[Value]
    while true:
      need(bytes, pos, 1)
      if bytes[pos] == END_BYTE:
        inc pos
        break
      children.add decodeValue(bytes, pos, depth - 1)
    case tag
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
    else:
      for i in 1 ..< children.len:
        if cmp(children[i - 1], children[i]) >= 0:
          fail "set members out of order or duplicated"
      set(children, marked)

  of 0xA:
    if header == END_BYTE:
      fail "END where a value was expected"
    fail "END carries no flag and no length"

  else: # 0x0, 0xB .. 0xF
    fail "invalid tag"

func decode*(bytes: openArray[byte]; maxDepth = 64): Value =
  var pos = 0
  result = decodeValue(bytes, pos, maxDepth)
  if pos != bytes.len:
    fail "trailing bytes after value"
