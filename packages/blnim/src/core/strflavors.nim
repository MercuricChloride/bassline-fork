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

func toDecimal*(str: DecimalString): DecimalString = str
func toDecimal*(str: sink string): DecimalString =
  if str.isDecimal:
    DecimalString(str)
  else:
    raise newException(InvalidDecStr, "not a canonical decimal integer: " & str)

func toDecimal*(n: int): DecimalString = toDecimal($n)

func parseInt*(str: DecimalString): int =
  discard parseInt(string(str), result)

func outOfRange() {.noreturn.} =
  raise newException(ValueError, "past the machine range")

func checkedAdd(a, b: int): int =
  if (b > 0 and a > high(int) - b) or (b < 0 and a < low(int) - b):
    outOfRange()
  a + b

func checkedSub(a, b: int): int =
  if (b < 0 and a > high(int) + b) or (b > 0 and a < low(int) + b):
    outOfRange()
  a - b

func checkedMul(a, b: int): int =
  if a != 0 and b != 0:
    if (a > 0 and b > 0 and a > high(int) div b) or
        (a > 0 and b < 0 and b < low(int) div a) or
        (a < 0 and b > 0 and a < low(int) div b) or
        (a < 0 and b < 0 and b < high(int) div a):
      outOfRange()
  a * b

func checkedDiv(a, b: int): int =
  if b == 0:
    raise newException(ValueError, "division by zero")
  if a == low(int) and b == -1:
    outOfRange()
  a div b

func checkedMod(a, b: int): int =
  if b == 0:
    raise newException(ValueError, "division by zero")
  if b == -1:
    # anything mod -1 is 0 — the identity, spoken directly, because
    # the machine op faults on low(int) even though 0 fits
    return 0
  a mod b

template binaryOp(name, checked) =
  func `name`*(a, b: DecimalString): DecimalString =
    checked(a.parseInt, b.parseInt).toDecimal

  func `name`*(a: DecimalString, b: int): DecimalString =
    checked(a.parseInt, b).toDecimal

  func `name`*(a: int, b: DecimalString): DecimalString =
    checked(a, b.parseInt).toDecimal

binaryOp(`+`, checkedAdd)
binaryOp(`-`, checkedSub)
binaryOp(`*`, checkedMul)
binaryOp(`div`, checkedDiv)
binaryOp(`mod`, checkedMod)

func `==`*(a: int, b: DecimalString): bool =
  a == parseInt(b)
func `==`*(a: DecimalString, b: int): bool =
  parseInt(a) == b

# ================ UTF-8 ================

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
