{.experimental: "strictFuncs".}

import ../core/values

type ReadError* = object of CatchableError

const
  Ws = {' ', '\t', '\n', '\r', ','}
  Delims = Ws + {'[', ']', '{', '}', '(', ')', ':', '#', '\'', '"', '`', ';'}

func isBareSpelling*(s: string): bool =
  ## whether a symbol may be spelled without quotes
  if s.len == 0 or s == "nil":
    return false
  for c in s:
    if c in Delims:
      return false
  if s[0] in {'0' .. '9'}:
    return false
  if s.len > 1 and s[0] == '-' and s[1] in {'0' .. '9'}:
    return false
  true

func fail(s: string, pos: int, msg: string) {.noreturn.} =
  var
    line = 1
    bol = 0
  for i in 0 ..< min(pos, s.len):
    if s[i] == '\n':
      inc line
      bol = i + 1
  raise
    newException(ReadError, "line " & $line & ", col " & $(pos - bol + 1) & ": " & msg)

func skipWs(s: string, pos: var int) =
  while pos < s.len:
    if s[pos] == ';':
      while pos < s.len and s[pos] != '\n':
        inc pos
    elif s[pos] in Ws:
      inc pos
    else:
      break

func nibble(s: string, pos: int, c: char): byte =
  case c
  of '0' .. '9':
    byte(ord(c) - ord('0'))
  of 'a' .. 'f':
    byte(ord(c) - ord('a') + 10)
  of 'A' .. 'F':
    byte(ord(c) - ord('A') + 10)
  else:
    fail(s, pos, "not a hex digit in bytes: " & c)

func quotedScan(s: string, pos: var int, q: char): string =
  ## body of a "string" or 'symbol' where pos is on the opening quote.
  ## Escapes are \q \\ \n \t \r
  let what = if q == '"': "string" else: "symbol"
  inc pos
  while true:
    if pos >= s.len:
      fail(s, pos, "unterminated " & what)
    let c = s[pos]
    if c == q:
      inc pos
      break
    elif c == '\\':
      if pos + 1 >= s.len:
        fail(s, pos, "unterminated " & what)
      let e = s[pos + 1]
      if e == q:
        result.add q
      elif e == '\\':
        result.add '\\'
      elif e == 'n':
        result.add '\n'
      elif e == 't':
        result.add '\t'
      elif e == 'r':
        result.add '\r'
      else:
        fail(s, pos, "unknown escape \\" & e & " in " & what)
      pos += 2
    else:
      result.add c
      inc pos

func value(s: string, pos: var int): Value

func datum(s: string, pos: var int): Value =
  case s[pos]
  of '[':
    inc pos
    var items: seq[Value]
    while true:
      skipWs(s, pos)
      if pos >= s.len:
        fail(s, pos, "unclosed [")
      if s[pos] == ']':
        inc pos
        break
      items.add value(s, pos)
    list(items)
  of '(':
    inc pos
    var items: seq[Value]
    while true:
      skipWs(s, pos)
      if pos >= s.len:
        fail(s, pos, "unclosed (")
      if s[pos] == ')':
        if items.len == 0:
          fail(s, pos, "record with no head")
        inc pos
        break
      items.add value(s, pos)
    record(items)
  of '{':
    inc pos
    var entries: seq[(Value, Value)]
    while true:
      skipWs(s, pos)
      if pos >= s.len:
        fail(s, pos, "unclosed {")
      if s[pos] == '}':
        inc pos
        break
      let k = value(s, pos)
      skipWs(s, pos)
      if pos >= s.len or s[pos] != ':':
        fail(s, pos, "dict entry needs ':' after its key")
      inc pos
      let v = value(s, pos)
      entries.add (k, v)
    try:
      dict(entries)
    except ValueError:
      fail(s, pos, "duplicate dict key")
  of '#':
    if pos + 1 >= s.len:
      fail(s, pos, "lone #")
    case s[pos + 1]
    of '{':
      pos += 2
      var els: seq[Value]
      while true:
        skipWs(s, pos)
        if pos >= s.len:
          fail(s, pos, "unclosed #{")
        if s[pos] == '}':
          inc pos
          break
        els.add value(s, pos)
      let v = values.set(els)
      if v.elements.len != els.len:
        fail(s, pos, "duplicate set member")
      v
    of '[':
      pos += 2
      var hex: string
      while true:
        if pos >= s.len:
          fail(s, pos, "unclosed #[")
        let c = s[pos]
        if c == ']':
          inc pos
          break
        elif c in Ws:
          inc pos
        else:
          hex.add c # validated pairwise below
          inc pos
      if hex.len mod 2 != 0:
        fail(s, pos, "bytes need an even count of hex digits")
      var bs = newSeq[byte](hex.len div 2)
      for i in 0 ..< bs.len:
        bs[i] = nibble(s, pos, hex[2 * i]) shl 4 or nibble(s, pos, hex[2 * i + 1])
      bytes(bs)
    else:
      fail(s, pos, "expected [ or { after #")
  of '"':
    let raw = quotedScan(s, pos, '"')
    try:
      text(raw)
    except InvalidUtf8Str:
      fail(s, pos, "malformed UTF-8 in string")
  of '\'':
    let raw = quotedScan(s, pos, '\'')
    try:
      sym(raw)
    except InvalidUtf8Str:
      fail(s, pos, "malformed UTF-8 in symbol")
  of ')', ']', '}', ':':
    fail(s, pos, "unexpected " & s[pos])
  else:
    let start = pos
    while pos < s.len and s[pos] notin Delims:
      inc pos
    let tok = s[start ..< pos]
    if tok[0] in {'0' .. '9'} or
        (tok.len > 1 and tok[0] == '-' and tok[1] in {'0' .. '9'}):
      if not isDecimal(tok):
        fail(s, start, "not a canonical number: " & tok)
      num(tok)
    elif tok == "nil":
      nilValue()
    else:
      try:
        sym(tok)
      except InvalidUtf8Str:
        fail(s, start, "malformed UTF-8 in symbol")

func value(s: string, pos: var int): Value =
  skipWs(s, pos)
  if pos >= s.len:
    fail(s, pos, "expected a value")
  if s[pos] == '`':
    inc pos
    if pos >= s.len:
      fail(s, pos, "mark with no value")
    if s[pos] == '`':
      fail(s, pos, "repeated mark")
    if s[pos] in Ws or s[pos] == ';':
      fail(s, pos, "mark separated from its value")
    mark(datum(s, pos))
  else:
    datum(s, pos)

func readDocument*(text: string): seq[Value] =
  ## read many values
  var pos = 0
  while true:
    skipWs(text, pos)
    if pos >= text.len:
      break
    result.add value(text, pos)

func readValue*(text: string): Value =
  ## read exactly one value
  let vs = readDocument(text)
  if vs.len != 1:
    raise newException(ReadError, "expected exactly one value, got " & $vs.len)
  vs[0]
