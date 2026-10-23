## The bassline textual syntax (data-model.org, "Textual Syntax") as a
## grammar that builds whatever `Make` builds: values whose sets and dicts
## hold their members in written order, for the pass in `values` to sort
## and check, or plain objects for the editor. Numbers are kept as spelled
## with the `_` separators removed, bytes as bytes, text and symbols
## decoded. Only the syntax is checked here. Repeats and encodings are the
## pass's business.

import std/[algorithm, sequtils, strutils, sugar, streams]
import petit_parser
import ./ce

type TextParser[T] = Parser[string, T]

const Delims* = " \t\n\r[]{}():'\";!"

proc unescaped(c: char): string =
  case c
  of 'n':
    "\n"
  of 't':
    "\t"
  of 'r':
    "\r"
  else:
    $c

proc escaped(s: string, q: char): string =
  ## the reader's escapes, \q \\ \n \t \r, so an atom is one line
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '\\':
      result.add "\\\\"
    of '\n':
      result.add "\\n"
    of '\t':
      result.add "\\t"
    of '\r':
      result.add "\\r"
    else:
      if c == q:
        result.add '\\'
      result.add c

proc quoted(q: char): TextParser[string] =
  let
    escape = (ch('\\') & chars($q & "\\ntr", "escape")).map(m => unescaped(m[1]))
    run = noneOf($q & "\\", "character").plus.flatten
  delimited(ch(q), ch(q), (run / escape).star).map(parts => parts.join)

proc space*(): TextParser[Nothing] =
  ## Whitespace or a `;` comment.
  chars(" \t\n\r", "whitespace").skip / (ch(';') & neg(newline()).star).skip

proc flat[V](entries: sink seq[(V, V)]): seq[V] =
  result = newSeqOfCap[V](2 * entries.len)
  for e in entries.mitems:
    result.add move e[0]
    result.add move e[1]

proc basslineValue*[V: Readable and Editable](
    extensions: seq[TextParser[V]] = @[], reserved: seq[string] = @[]
): TextParser[V] =
  ## One value, bare. `extensions` are tried before a symbol, and the
  ## `reserved` words are never read as one.
  mixin cmp
  let
    ws = space()
    value = undefined[string, V]("value")
    form = value.trim(ws)
    ends = notAhead(noneOf(Delims, "symbol character"))

    hex = chars(HexDigits, "hex digit")
    hexBody = (hex & (ch('_').optional & hex).star).skip.optional
    bytesTok = sequence((str("0x"), hexBody, ends))
      .flatten("bytes")
      .where(b => (b.len - 2 - b.count('_')) mod 2 == 0, "an even count of hex digits")
      .map(b => V.atom(parseHexStr(b[2 .. ^1].replace("_", "")), bBytes, false))
    numberStart = digit().skip / (ch('-') & digit()).skip
    digits = ch('0').skip / (between('1', '9') & (ch('_').optional & digit()).star).skip
    numberTok = sequence((ch('-').optional, digits, ends))
      .flatten("number")
      .where(n => n != "-0", "a number")
      .map(n => V.atom(n.replace("_", ""), bNum, false))
    nilTok = (str("nil") & ends).map(_ => V.null(false))
    text = quoted('"').map((s: sink string) => V.atom(s, bText, false))
    quotedSymbol = quoted('\'').map((s: sink string) => V.atom(s, bSym, false))
    bare = noneOf(Delims, "symbol character").plus.flatten("symbol")
    keyword = choice(reserved.map(w => (str(w) & ends).skip("'" & w & "'")))
    symbol = sequence((notAhead(numberStart), notAhead(keyword), bare)).pick(2).map(
        (s: sink string) => V.atom(s, bSym, false)
      )
    rawAtom = choice(
      @[bytesTok, numberTok, nilTok, text, quotedSymbol] & extensions & @[symbol]
    )
    atom = (rawAtom & (ch('!') & ends).skip.optional).map(
      proc(m: sink (V, Option[Nothing])): auto =
        if m[1].isSome:
          m[0].setMark(true)
        move m[0]
    )

    list = delimited(ch('['), ch(']').trim(ws), form.star).map(
        (items: sink seq[V]) => V.frame(items, bList, false)
      )
    record = delimited(ch('('), ch(')').trim(ws), form.plus).map(
        (items: sink seq[V]) => V.frame(items, bRec, false)
      )
    colon = ch(':').trim(ws)
    entries = ((form & colon).pick(0) & form).star
    members = form.star
    # the first member, read once, decides between a dict and a set
    braced = (form & (colon & form).pick(1).optional).callCC(
      proc(next: TextParser[(V, Option[V])], ctx: Context[string]): Result[V] =
        var f = next.parseOn(ctx)
        if not f.isSuccess:
          return failedAs(V, f)
        var (k, v) = f.take
        if v.isSome:
          var r = entries.parseOn(ctx.at(f.pos))
          if not r.isSuccess:
            return failedAs(V, r)
          var es = r.take
          es.insert((move k, v.get), 0)
          es.sort((a, b) => cmp(a[0], b[0]))
          succeed(V.frame(flat(es), bDict, false), r.pos)
        else:
          var r = members.parseOn(ctx.at(f.pos))
          if not r.isSuccess:
            return failedAs(V, r)
          var items = r.take
          items.insert(move k, 0)
          items.sort(cmp)
          succeed(V.frame(items, bSet, false), r.pos)
    )
    emptyDict = colon.map(_ => V.frame(@[], bDict, false))
    emptySet = epsilon[string, V](V.frame(@[], bSet, false))
    braces = delimited(ch('{'), ch('}').trim(ws), emptyDict / braced / emptySet)
    frame = list / record / braces
    markedFrame = (ch('!') & frame).pick(1).map(
        proc(m: sink V): auto =
          m.setMark(true)
          m
      )

  value.define(markedFrame / frame / atom)
  value

proc basslineForm*[V: Readable and Editable](
    extensions: seq[TextParser[V]] = @[], reserved: seq[string] = @[]
): TextParser[V] =
  ## One value and the space around it.
  basslineValue(extensions, reserved).trim(space())

proc basslineParser*[V: Readable and Editable](): TextParser[V] =
  ## Exactly one value.
  basslineForm[V]().complete.resolve

proc basslineDocument*[V: Readable and Editable](): TextParser[seq[V]] =
  ## Any number of values, including none.
  basslineForm[V]().star.trim(space()).complete.resolve

proc openChar(k: Kind): char =
  case k
  of bList:
    '['
  of bRec:
    '('
  of bDict, bSet:
    '{'
  else:
    default(char)

proc closeChar(k: Kind): char =
  case k
  of bList:
    ']'
  of bRec:
    ')'
  of bDict, bSet:
    '}'
  else:
    default(char)

func isBareSpelling*(s: string): bool =
  ## whether a symbol may be spelled without quotes
  if s.len == 0 or s == "nil":
    return false
  if s[0] in Digits:
    return false
  if s.len > 1 and s[0] == '-' and s[1] in Digits:
    return false
  for c in s:
    if c in Delims or ord(c) < 0x20:
      return false
  true

proc writeWalkable[T: Walkable](v: T, stream: StringStream) =
  mixin children

  template writeMark(it) =
    if it.mark:
      stream.write("!")

  case v.kind
  of bNil:
    stream.write("nil")
    writeMark(v)
  of bNum:
    stream.write(v.digits)
    writeMark(v)
  of bText:
    stream.write('"')
    stream.write(v.payload.escaped('"'))
    stream.write('"')
    writeMark(v)
  of bSym:
    let s = v.payload
    if s.isBareSpelling:
      stream.write s
    else:
      stream.write('\'')
      stream.write(v.payload.escaped('\''))
      stream.write('\'')
    writeMark(v)
  of bBytes:
    stream.write("0x")
    stream.write(v.payload.toHex)
    writeMark(v)
  of bList, bRec, bSet:
    writeMark(v)
    stream.write(v.kind.openChar)
    let hi = v.len - 1
    for i in 0 .. hi:
      writeWalkable(v.getChild(i), stream)
      if i != hi:
        stream.write(' ')
    stream.write(v.kind.closeChar)
  of bDict:
    writeMark(v)
    stream.write(v.kind.openChar)
    let hi = v.len - 1
    for i in 0 .. hi:
      writeWalkable(v.getChild(i), stream)
      if i != hi:
        if i mod 2 == 0:
          stream.write(": ")
        else:
          stream.write(" ")
    if v.len == 0:
      stream.write(':')
    stream.write(v.kind.closeChar)

proc toBlText*[T: Walkable](self: T): string =
  var s = newStringStream()
  writeWalkable(self, s)
  move s.data

proc parse*(T: typedesc[Walkable], s: string): T =
  var
    p = basslineParser[T]()
    r = p.parse(s)
  r.take

template makePrintable*(Ty) =
  proc `$`*(self: Ty): string =
    self.toBlText

when isMainModule:
  import ./[values, raw]

  makePrintable RawValue
  makePrintable ValueObj

  let text = """
    (hello! bassline 0xdeadbeef)
  """

  let p = RawValue.parse(text)

  echo p