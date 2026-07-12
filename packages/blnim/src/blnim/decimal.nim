{.experimental: "strictFuncs".}

type
  DecimalString* = distinct string
  InvalidDecStr* = object of CatchableError

func isDecimal*(str: string): bool =
  ## Canonical integer spelling per data-model.org: optional '-',
  ## then digits with no leading zero; zero is "0"; no "-0", no "+".
  let start = if str.len > 0 and str[0] == '-': 1 else: 0
  if str.len == start:
    return false
  for i in start ..< str.len:
    if str[i] notin {'0'..'9'}:
      return false
  if str[start] == '0' and str.len - start > 1:
    return false
  if str == "-0":
    return false
  true

func toDecimal*(str: string): DecimalString =
  if str.isDecimal:
    DecimalString(str)
  else:
    raise newException(InvalidDecStr, "not a canonical decimal integer: " & str)

func `$`*(str: DecimalString): string =
  string(str)

func len*(str: DecimalString): int =
  string(str).len

func cmp*(a, b: DecimalString): int =
  string(a).cmp(string(b))
