import utils

type
  Utf8String* = distinct string
  InvalidUtf8Str* = object of CatchableError

strDefaults(Utf8String)

func isCont(b: byte): bool =
  (b and 0xC0) == 0x80

func isValidUtf8*(s: openArray[byte]): bool =
  var i = 0
  while i < s.len:
    case s[i]
    # ascii range, so 1 byte,
    of 0x00 .. 0x7F:
      inc i
    # 2 byte range
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

func toString*(s: openArray[byte]): string =
  result = newString(s.len)
  for i in 0 ..< s.len:
    result[i] = char(s[i])

func toValidUtf8*(bytes: openArray[byte]): Utf8String =
  if bytes.isValidUtf8:
    return Utf8String(bytes.toString)
  else:
    raise newException(InvalidUtf8Str, "malformed utf8 bytes")

func toValidUtf8*(str: Utf8String): Utf8String = str
func toValidUtf8*(str: string): Utf8String = str.toOpenArrayByte(0, str.high).toValidUtf8
