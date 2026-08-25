## A bassline textual syntax reader
##
## Values are built with the builders, never as raw bytes: text is a
## small, lightweight format, and building through the same
## constructors the bl macro targets keeps one construction surface.
## The two payload laws the text needs (canonical integer spellings,
## UTF-8) are codec's, used here so a bad spelling is refused with a
## line and column instead of later at finalize. Sets and dicts land
## in their trees as they are read, so canonical order is by
## construction

import std/strutils
import ./[builders, codec]
export builders

type
  ReadError* = object of CatchableError

const
  Ws = {' ', '\t', '\n', '\r'}
  Delims = Ws + {'[', ']', '{', '}', '(', ')', ':', '\'', '"', ';', '!'}
  Digits = {'0' .. '9'}
  HexDigits = Digits + {'a' .. 'f', 'A' .. 'F'}
  FrameKinds = {bList, bRec, bDict, bSet}

func isBareSpelling*(s: string): bool =
  ## whether a symbol may be spelled without quotes: it has to read
  ## back as itself — not empty, not nil, not a number, and free of
  ## delimiters and control characters
  if s.len == 0 or s == "nil": return false
  if s[0] in Digits: return false
  if s.len > 1 and s[0] == '-' and s[1] in Digits: return false
  for c in s:
    if c in Delims or ord(c) < 0x20: return false
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

func checkUtf8(s: string, pos: int, raw: string, what: string) =
  if not isValidUtf8(raw.toOpenArrayByte(0, raw.high)):
    fail(s, pos, "malformed UTF-8 in " & what)

proc value(s: string, pos: var int): Value

proc datum(s: string, pos: var int): Value =
  case s[pos]
  of '[':
    inc pos
    result = initList()
    while true:
      skipWs(s, pos)
      if pos >= s.len:
        fail(s, pos, "unclosed [")
      if s[pos] == ']':
        inc pos
        break
      result.items.add value(s, pos)
  of '(':
    inc pos
    skipWs(s, pos)
    if pos >= s.len:
      fail(s, pos, "unclosed (")
    if s[pos] == ')':
      fail(s, pos, "record with no head")
    result = initRec(value(s, pos))
    while true:
      skipWs(s, pos)
      if pos >= s.len:
        fail(s, pos, "unclosed (")
      if s[pos] == ')':
        inc pos
        break
      result.items.add value(s, pos)
  of '{':
    # {} is the empty set, {:} the empty dict; otherwise the first
    # member decides: a ':' after it makes the frame a dictionary
    inc pos
    skipWs(s, pos)
    if pos >= s.len:
      fail(s, pos, "unclosed {")
    if s[pos] == '}':
      inc pos
      return initSet()
    if s[pos] == ':':
      inc pos
      skipWs(s, pos)
      if pos >= s.len:
        fail(s, pos, "unclosed {")
      if s[pos] != '}':
        fail(s, pos, "'{:' is the empty dictionary; expected '}'")
      inc pos
      return initDict()
    let first = value(s, pos)
    skipWs(s, pos)
    if pos >= s.len:
      fail(s, pos, "unclosed {")
    if s[pos] == ':':
      inc pos
      result = initDict()
      var k = first
      while true:
        if k in result.dict:
          fail(s, pos, "duplicate dict key")
        result.dict[k] = value(s, pos)
        skipWs(s, pos)
        if pos >= s.len:
          fail(s, pos, "unclosed {")
        if s[pos] == '}':
          inc pos
          break
        k = value(s, pos)
        skipWs(s, pos)
        if pos >= s.len or s[pos] != ':':
          fail(s, pos, "dict entry needs ':' after its key")
        inc pos
    else:
      result = initSet()
      var m = first
      while true:
        if m in result.elements:
          fail(s, pos, "duplicate set member")
        result.elements[m] = true
        skipWs(s, pos)
        if pos >= s.len:
          fail(s, pos, "unclosed {")
        if s[pos] == '}':
          inc pos
          break
        if s[pos] == ':':
          fail(s, pos, "':' in a set; a dictionary is {key: value}")
        m = value(s, pos)
  of '"':
    let start = pos
    let raw = quotedScan(s, pos, '"')
    checkUtf8(s, start, raw, "string")
    result = text(raw)
  of '\'':
    let start = pos
    let raw = quotedScan(s, pos, '\'')
    checkUtf8(s, start, raw, "symbol")
    result = sym(raw)
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
      result = bytes(bs)
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
      if not isValidInt(digits.toOpenArrayByte(0, digits.high)):
        fail(s, start, "not a canonical number: " & tok)
      try:
        result = num(parseBiggestInt(digits).int)
      except ValueError:
        fail(s, start, "number outside the range this reading holds: " & tok)
    elif tok == "nil":
      result = null()
    else:
      checkUtf8(s, start, tok, "symbol")
      result = sym(tok)

proc value(s: string, pos: var int): Value =
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
    v.marked = true
  elif prefixMarked:
    v.marked = true
  v

proc readDocument*(text: string, values: var seq[Value]) =
  ## read many values into the seq values
  var pos = 0
  while true:
    skipWs(text, pos)
    if pos >= text.len:
      break
    values.add value(text, pos)

proc readDocument*(text: string): seq[Value] =
  readDocument(text, result)

proc readValue*(text: string): Value =
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
  ## rec (…), list […], set {…} ({} empty), dict {k: v …} ({:} empty).
  ## The mark is a prefix on frames and a suffix on atoms. Symbols are
  ## bare when they read back as themselves, single-quoted otherwise.
  let core =
    case v.kind
    of bNil:
      "nil"
    of bNum:
      $v.num
    of bSym:
      if isBareSpelling(v.text):
        v.text
      else:
        "'" & escaped(v.text, '\'') & "'"
    of bText:
      "\"" & escaped(v.text, '"') & "\""
    of bBytes:
      var hex = "0x"
      for b in v.bytes:
        hex.add b.toHex.toLowerAscii
      hex
    of bList, bRec:
      var parts = ""
      for c in v.items:
        if parts.len > 0:
          parts.add ' '
        parts.add $c
      if v.kind == bList:
        "[" & parts & "]"
      else:
        "(" & parts & ")"
    of bSet:
      var parts = ""
      for k, _ in v.elements:
        if parts.len > 0:
          parts.add ' '
        parts.add $k
      "{" & parts & "}"
    of bDict:
      if v.dict.len == 0:
        "{:}"
      else:
        var parts = ""
        for k, val in v.dict:
          if parts.len > 0:
            parts.add ' '
          parts.add $k & ": " & $val
        "{" & parts & "}"
  if not v.marked:
    core
  elif v.kind in FrameKinds:
    "!" & core
  else:
    core & "!"