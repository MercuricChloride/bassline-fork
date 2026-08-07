include pkg/prelude
from std/strutils import toHex, toLowerAscii
import pkg/core/values

type ReadError* = object of CatchableError

const
  Ws = {' ', '\t', '\n', '\r'}
  Delims = Ws + {'[', ']', '{', '}', '(', ')', ':', '\'', '"', ';', '!'}
  Digits = {'0' .. '9'}
  HexDigits = Digits + {'a' .. 'f', 'A' .. 'F'}

func isBareSpelling*(s: string): bool =
  ## whether a symbol may be spelled without quotes
  if s.len == 0 or s == "nil":
    return false
  for c in s:
    if c in Delims:
      return false
  if s[0] in Digits:
    return false
  if s.len > 1 and s[0] == '-' and s[1] in Digits:
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
    var b = open(bList)
    while true:
      skipWs(s, pos)
      if pos >= s.len:
        fail(s, pos, "unclosed [")
      if s[pos] == ']':
        inc pos
        break
      b.add value(s, pos)
    close b
  of '(':
    inc pos
    var b = open(bRecord)
    while true:
      skipWs(s, pos)
      if pos >= s.len:
        fail(s, pos, "unclosed (")
      if s[pos] == ')':
        if b.len == 0:
          fail(s, pos, "record with no head")
        inc pos
        break
      b.add value(s, pos)
    close b
  of '{':
    # the open frame starts as a set and the first ':'
    # rekinds it to a dictionary.
    inc pos
    var b = open(bSet)
    skipWs(s, pos)
    if pos >= s.len:
      fail(s, pos, "unclosed {")
    if s[pos] == '}':
      inc pos
    elif s[pos] == ':':
      inc pos
      b.rekind(bDict)
      skipWs(s, pos)
      if pos >= s.len:
        fail(s, pos, "unclosed {")
      if s[pos] != '}':
        fail(s, pos, "'{:' is the empty dictionary; expected '}'")
      inc pos
    else:
      let first = value(s, pos)
      skipWs(s, pos)
      if pos >= s.len:
        fail(s, pos, "unclosed {")
      if s[pos] == ':':
        b.rekind(bDict)
        inc pos
        b.add(first, value(s, pos))
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
          b.add(k, value(s, pos))
      else:
        b.add first
        while true:
          skipWs(s, pos)
          if pos >= s.len:
            fail(s, pos, "unclosed {")
          if s[pos] == '}':
            inc pos
            break
          if s[pos] == ':':
            fail(s, pos, "':' in a set; a dictionary is {key: value}")
          b.add value(s, pos)
    if b.kind == bDict:
      try:
        close b
      except ValueError:
        fail(s, pos, "duplicate dict key")
    else:
      let n = b.len
      let v = close b
      if v.contents.len != n:
        fail(s, pos, "duplicate set member")
      v
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
  of ')', ']', '}', ':', '!':
    fail(s, pos, "unexpected " & s[pos])
  else:
    let start = pos
    while pos < s.len and s[pos] notin Delims:
      inc pos
    let tok = s[start ..< pos]
    if tok.len >= 2 and tok[0] == '0' and tok[1] == 'x':
      # a bytestring: 0x then an even count of hex digits, '_' between
      # digits as a visual separator
      var hex: string
      for i in 2 ..< tok.len:
        let c = tok[i]
        if c == '_':
          if tok[i - 1] notin HexDigits or i + 1 >= tok.len or
              tok[i + 1] notin HexDigits:
            fail(s, start + i, "'_' sits between digits")
        elif c in HexDigits:
          hex.add c
        else:
          fail(s, start + i, "not a hex digit in bytes: " & c)
      if hex.len mod 2 != 0:
        fail(s, start, "bytes need an even count of hex digits")
      var bs = newSeq[byte](hex.len div 2)
      for i in 0 ..< bs.len:
        bs[i] = nibble(s, start, hex[2 * i]) shl 4 or nibble(s, start, hex[2 * i + 1])
      bytes(bs)
    elif tok[0] in Digits or
        (tok.len > 1 and tok[0] == '-' and tok[1] in Digits):
      var digits: string
      for i in 0 ..< tok.len:
        let c = tok[i]
        if c == '_':
          if tok[i - 1] notin Digits or i + 1 >= tok.len or
              tok[i + 1] notin Digits:
            fail(s, start + i, "'_' sits between digits")
        else:
          digits.add c
      if not isDecimal(digits):
        fail(s, start, "not a canonical number: " & tok)
      num(digits)
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
  var prefixMarked = false
  if s[pos] == '!':
    # a mark in front belongs to a frame; it must touch the bracket
    inc pos
    if pos >= s.len:
      fail(s, pos, "mark with no value")
    if s[pos] == '!':
      fail(s, pos, "repeated mark")
    if s[pos] in Ws or s[pos] == ';':
      fail(s, pos, "mark separated from its value")
    if s[pos] notin {'(', '[', '{'}:
      fail(s, pos, "only a frame is marked in front; an atom is marked behind: x!")
    prefixMarked = true
  let frame = s[pos] in {'(', '[', '{'}
  var v = datum(s, pos)
  if pos < s.len and s[pos] == '!':
    # a mark behind belongs to an atom; it must touch the atom and
    # end at a delimiter
    if frame:
      fail(s, pos, "a frame is marked in front: !(…)")
    inc pos
    if pos < s.len and s[pos] notin Delims:
      fail(s, pos, "a marked atom ends at a delimiter")
    v = mark(v)
  elif prefixMarked:
    v = mark(v)
  v

func readDocument*(text: string, values: var seq[Value]) =
  ## read many values into the seq values
  var pos = 0
  while true:
    skipWs(text, pos)
    if pos >= text.len:
      break
    values.add value(text, pos)

func readDocument*(text: string): seq[Value] =
  readDocument(text, result)

func readValue*(text: string): Value =
  ## read exactly one value
  var values = readDocument(text)
  if values.len != 1:
    raise newException(ReadError, "expected exactly one value, got " & $values.len)
  move values[0]

## ================ PRINTING ================

func escaped(s: string, q: char): string =
  for c in s:
    if c == q or c == '\\':
      result.add '\\'
    result.add c

func `$`*(v: Value): string =
  let core =
    case v.kind
    of bNil:
      "nil"
    of bNum:
      $v.num
    of bSym:
      let name = $v.text
      if isBareSpelling(name):
        name
      else:
        "'" & escaped(name, '\'') & "'"
    of bText:
      "\"" & escaped($v.text, '"') & "\""
    of bBytes:
      var hex = "0x"
      for b in v.bytes:
        hex.add b.toHex.toLowerAscii
      hex
    of bList, bRecord:
      var parts = ""
      for c in v.contents:
        if parts.len > 0:
          parts.add ' '
        parts.add $c
      if v.kind == bList:
        "[" & parts & "]"
      else:
        "(" & parts & ")"
    of bSet:
      var parts = ""
      for c in v.contents:
        if parts.len > 0:
          parts.add ' '
        parts.add $c
      "{" & parts & "}"
    of bDict:
      if v.contents.len == 0:
        "{:}"
      else:
        var parts = ""
        for k, val in v.pairs:
          if parts.len > 0:
            parts.add ' '
          parts.add $k
          parts.add ": "
          parts.add $val
        "{" & parts & "}"
  if not v.marked:
    core
  elif v.isFrame:
    "!" & core
  else:
    core & "!"