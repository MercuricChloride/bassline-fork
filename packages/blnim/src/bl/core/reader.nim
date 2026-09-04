## A bassline textual syntax reader
##
## Values are built with the builders, never as raw bytes: text is a
## small, lightweight format, and building through the same
## constructors the bl macro targets keeps one construction surface.
## The two payload laws the text needs (canonical integer spellings,
## UTF-8) are codec's, used here so a bad spelling is refused with a
## line and column instead of later at seal. Sets and dicts land
## in their trees as they are read, so canonical order is by
## construction

import std/strutils
import builders, codec
export builders

type
  ReadError* = object of CatchableError
  Incomplete* = object of ReadError

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

func where(s: string, pos: int): string =
  var
    line = 1
    bol = 0
  for i in 0 ..< min(pos, s.len):
    if s[i] == '\n':
      inc line
      bol = i + 1
  "line " & $line & ", col " & $(pos - bol + 1) & ": "

func fail(s: string, pos: int, msg: string) {.noreturn.} =
  raise newException(ReadError, where(s, pos) & msg)

func incomplete(s: string, pos: int, msg: string) {.noreturn.} =
  raise newException(Incomplete, where(s, pos) & msg)

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
      incomplete(s, pos, "unterminated " & what)
    let c = s[pos]
    if c == q:
      inc pos
      break
    elif c == '\\':
      if pos + 1 >= s.len:
        incomplete(s, pos, "unterminated " & what)
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
  if not isValidUtf8(raw.toBytes):
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
        incomplete(s, pos, "unclosed [")
      if s[pos] == ']':
        inc pos
        break
      result.items.add value(s, pos)
  of '(':
    inc pos
    skipWs(s, pos)
    if pos >= s.len:
      incomplete(s, pos, "unclosed (")
    if s[pos] == ')':
      fail(s, pos, "record with no head")
    result = initRec(value(s, pos))
    while true:
      skipWs(s, pos)
      if pos >= s.len:
        incomplete(s, pos, "unclosed (")
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
      incomplete(s, pos, "unclosed {")
    if s[pos] == '}':
      inc pos
      return initSet()
    if s[pos] == ':':
      inc pos
      skipWs(s, pos)
      if pos >= s.len:
        incomplete(s, pos, "unclosed {")
      if s[pos] != '}':
        fail(s, pos, "'{:' is the empty dictionary; expected '}'")
      inc pos
      return initDict()
    let first = value(s, pos)
    skipWs(s, pos)
    if pos >= s.len:
      incomplete(s, pos, "unclosed {")
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
          incomplete(s, pos, "unclosed {")
        if s[pos] == '}':
          inc pos
          break
        k = value(s, pos)
        skipWs(s, pos)
        if pos >= s.len:
          incomplete(s, pos, "dict entry needs ':' after its key")
        if s[pos] != ':':
          fail(s, pos, "dict entry needs ':' after its key")
        inc pos
    else:
      result = initSet()
      var m = first
      while true:
        if m in result.els:
          fail(s, pos, "duplicate set member")
        result.els[m] = true
        skipWs(s, pos)
        if pos >= s.len:
          incomplete(s, pos, "unclosed {")
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
      try:
        result = num(digits)   # the spelling's law is the builder's
      except ValueError:
        fail(s, start, "not a canonical number: " & tok)
    elif tok == "nil":
      result = null()
    else:
      checkUtf8(s, start, tok, "symbol")
      result = sym(tok)

proc value(s: string, pos: var int): Value =
  skipWs(s, pos)
  if pos >= s.len:
    incomplete(s, pos, "expected a value")
  var prefixMarked = false
  if s[pos] == '!':
    # a mark in front belongs to a frame; it must touch the bracket
    inc pos
    if pos >= s.len:
      incomplete(s, pos, "mark with no value")
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
    v.mark = true
  elif prefixMarked:
    v.mark = true
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
  ## the reader's escapes -- \q \\ \n \t \r -- so an atom is one line
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    else:
      if c == q: result.add '\\'
      result.add c

func escapedLen(s: string, q: char): int =
  for c in s:
    inc result
    if c == q or c in {'\\', '\n', '\t', '\r'}: inc result

func hexString*(bytes: openArray[byte]): string =
  result = "0x"
  for b in bytes:
    result.add b.toHex.toLowerAscii

func printAtom(v: Value): string =
  case v.kind
  of bNil: 
    result = "nil"
  of bNum: 
    result = $v.num
  of bSym:
    if isBareSpelling(v.text):
      result = v.text
    else:
      result = "'" & escaped(v.text, '\'') & "'"
  of bText: 
    result = "\"" & escaped(v.text, '"') & "\""
  of bBytes:
    result = v.bytes.hexString
  else: discard
  if v.mark: result.add '!'

func atomLen(v: Value): int =
  ## length of the string spelling of an atom
  ## without materializing the string
  case v.kind
  of bNil: result = 3
  of bNum: result = spellingLen(v.num)
  of bSym:
    result = if isBareSpelling(v.text): v.text.len
             else: 2 + escapedLen(v.text, '\'')
  of bText: result = 2 + escapedLen(v.text, '"')
  of bBytes: result = 2 + 2 * v.bytes.len
  else: discard
  if v.mark: inc result

func opener(v: Value): string =
  if v.mark: result.add '!'
  case v.kind
  of bList: result.add '['
  of bRec: result.add '('
  else: result.add '{'

func closer(v: Value): char =
  case v.kind
  of bList: ']'
  of bRec: ')'
  else: '}'

func members(v: Value): int =
  case v.kind
  of bList, bRec: v.items.len
  of bSet: v.els.len
  of bDict: v.dict.len
  else: 0

template eachMember(v: Value, m, body: untyped) =
  case v.kind
  of bList, bRec:
    for m in v.items: body
  of bSet:
    for m in v.els.keys: body
  else: discard

func flatLen(v: Value, room: int): int =
  ## the width of the one-line spelling, returning
  ## early if it would overflow the remaining room
  if v.kind notin FrameKinds:
    return atomLen(v)
  if v.kind == bDict and v.dict.len == 0:
    return opener(v).len + 2 # {:}
  result = opener(v).len + 1 # opener and closer
  var first = true
  if v.kind == bDict:
    for k, val in v.dict:
      if not first: inc result
      first = false
      result += flatLen(k, room - result) + 2   # ": "
      result += flatLen(val, room - result)
      if result > room: return
  else:
    eachMember(v, m):
      if not first: inc result
      first = false
      result += flatLen(m, room - result)
      if result > room: return

func column(o: string): int =
  ## where the next character lands on the current line
  var i = o.len
  while i > 0 and o[i - 1] != '\n': dec i
  o.len - i

func newline(o: var string, align: int) =
  o.add '\n'
  for _ in 0 ..< align: o.add ' '

func putFlat(o: var string, v: Value) =
  if v.kind notin FrameKinds:
    o.add printAtom(v)
    return
  o.add opener(v)
  if v.kind == bDict and v.dict.len == 0:
    o.add ':'
  var first = true
  if v.kind == bDict:
    for k, val in v.dict:
      if not first: o.add ' '
      first = false
      o.putFlat k
      o.add ": "
      o.putFlat val
  else:
    eachMember(v, m):
      if not first: o.add ' '
      first = false
      o.putFlat m
  o.add closer(v)

func put(o: var string, v: Value, width, trail: int)

func putMembers(o: var string, v: Value, skip, align, width, trail: int) =
  ## the members of a list, set or record (past its head): the first
  ## at the current column, the rest aligned with it filling as many
  ## per line as we can fit when all are atoms, otherwise one per line
  let n = members(v)
  var fill = true
  var i = 0
  eachMember(v, m):
    if i >= skip and m.kind in FrameKinds: fill = false
    inc i
  i = 0
  eachMember(v, m):
    if i >= skip:
      let after = if i == n - 1: 1 + trail else: 0 # the closers to come
      if i > skip:
        if fill and o.column + 1 + atomLen(m) + after <= width:
          o.add ' '
        else:
          o.newline(align)
      o.put(m, width, after)
    inc i

func put(o: var string, v: Value, width, trail: int) =
  ## `v` at the current column: flat when it fits with `trail`
  ## characters still to come on its last line, else opened
  if v.kind notin FrameKinds or width == high(int) or members(v) == 0:
    o.putFlat v
    return
  let col = o.column
  if col + flatLen(v, width - col - trail) + trail <= width:
    o.putFlat v
    return
  o.add opener(v)
  case v.kind
  of bDict:
    let align = o.column
    var i = 0
    for k, val in v.dict:
      if i > 0: o.newline(align)
      o.put(k, width, 2)
      o.add ": "
      o.put(val, width, if i == v.dict.len - 1: 1 + trail else: 0)
      inc i
  of bRec:
    let only = v.items.len == 1
    o.put(v.items[0], width, if only: 1 + trail else: 0)
    if not only:
      var align = o.column + 1
      if align > width div 2:
        # head too wide to align after, so members go under it
        align = col + opener(v).len
        o.newline(align)
      else:
        o.add ' '
      o.putMembers(v, 1, align, width, trail)
  else:
    o.putMembers(v, 0, o.column, width, trail)
  o.add closer(v)

func pretty*(v: Value, width = 80): string =
  ## `v` laid out within `width` columns
  result.put(v, width, 0)

func `$`*(v: Value): string =
  pretty(v, high(int))