include pkg/prelude
from std/parseutils import parseInt

template strDefaults*(T: typedesc) =

  func len*(s: T): int {.borrow.}

  func `==`*(a, b: T): bool {.borrow.}

  func `==`*(a: T, b: string): bool = string(a) == b

  func `==`*(a: string, b: T): bool = a == string(b)

  func `cmp`*(a, b: T): int {.borrow.}

  func `$`*(a: T): string {.borrow.}
  func `[]`*[I](a: T, i: I): char =
    string(a)[i]

  func toString*(s: sink T): string =
    string(s)

type
  DecimalString* = distinct string
  Utf8String* = distinct string
  InvalidDecStr* = object of CatchableError
  InvalidUtf8Str* = object of CatchableError

strDefaults(DecimalString)
strDefaults(Utf8String)

# ================ DECIMAL ================

func isDecimal*(str: string): bool =
  ## Canonical integer spelling per the data model
  ##
  ## optional '-' for negative non-zero values
  ##
  ## then digits with no leading zero
  ##
  ## zero is just "0"
  let start = if str.len > 0 and str[0] == '-': 1 else: 0
  if str.len == start:
    return false
  for c in str.toOpenArray(start, str.high):
    if c notin {'0'..'9'}:
      return false
  if str[start] == '0' and str.len - start > 1:
    return false
  if str == "-0":
    return false
  true

func toDecimal*(str: DecimalString): DecimalString = str
func toDecimal*(str: sink string): DecimalString =
  if str.isDecimal:
    DecimalString(str)
  else:
    raise newException(InvalidDecStr, "not a canonical decimal integer: " & str)

func toDecimal*(n: int): DecimalString = toDecimal($n)

func parseInt*(str: sink DecimalString): int =
  discard parseInt(str.toString, result)

template binaryOp(name) =
    func `name`*(a, b: DecimalString): DecimalString =
      name(a.parseInt, b.parseInt).toDecimal
    
    func `name`*(a: DecimalString, b: int): DecimalString =
      name(a.parseInt, b).toDecimal
    
    func `name`*(a: int, b: DecimalString): DecimalString =
      name(a, b.parseInt).toDecimal

binaryOp(`+`)
binaryOp(`-`)
binaryOp(`*`)
binaryOp(`div`)
binaryOp(`mod`)

func `==`*(a: int, b: DecimalString): bool =
  a == parseInt(b)
func `==`*(a: DecimalString, b: int): bool =
  parseInt(a) == b

# ================ UTF-8 ================

func isCont(b: byte): bool =
  (b and 0xC0) == 0x80

func isValidUtf8*(s: openArray[byte]): bool =
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

func toString*(s: openArray[byte]): string =
  result = newString(s.len)
  for i, b in s:
    result[i] = char(b)

func toBytes*(s: string): seq[byte] =
  result = newSeqUninit[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], addr s[0], s.len)

func toValidUtf8*(bytes: openArray[byte]): Utf8String =
  if bytes.isValidUtf8:
    return Utf8String(bytes.toString)
  else:
    raise newException(InvalidUtf8Str, "malformed utf8 bytes")

func toValidUtf8*(str: sink Utf8String): Utf8String = str

func toValidUtf8*(str: sink string): Utf8String =
  str.toOpenArrayByte(str.low, str.high).toValidUtf8