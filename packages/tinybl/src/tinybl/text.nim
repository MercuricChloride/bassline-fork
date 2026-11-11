import std/[sequtils, strutils, sugar]
import petit_parser
import ./micro

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

proc basslineValue*(
    extensions: seq[TextParser[Node]] = @[], reserved: seq[string] = @[]
): TextParser[Node] =
  ## One value, bare. `extensions` are tried before a symbol, and the
  ## `reserved` words are never read as one.
  let
    ws = space()
    value = undefined[string, Node]("value")
    form = value.trim(ws)
    ends = notAhead(noneOf(Delims, "symbol character"))

    hex = chars(HexDigits, "hex digit")
    hexBody = (hex & (ch('_').optional & hex).star).skip.optional
    bytesTok = sequence((str("0x"), hexBody, ends))
      .flatten("bytes")
      .where(b => (b.len - 2 - b.count('_')) mod 2 == 0, "an even count of hex digits")
      .map(b => Bytes(parseHexStr(b[2 .. ^1].replace("_", "")), false))
    numberStart = digit().skip / (ch('-') & digit()).skip
    digits = ch('0').skip / (between('1', '9') & (ch('_').optional & digit()).star).skip
    numberTok = sequence((ch('-').optional, digits, ends))
      .flatten("number")
      .where(n => n != "-0", "a number")
      .map(n => Num(n.replace("_", ""), false))
    nilTok = (str("nil") & ends).map(_ => null().toNode)
    text = quoted('"').map((s: sink string) => Text(s, false))
    quotedSymbol = quoted('\'').map((s: sink string) => Sym(s, false))
    bare = noneOf(Delims, "symbol character").plus.flatten("symbol")
    keyword = choice(reserved.map(w => (str(w) & ends).skip("'" & w & "'")))
    symbol = sequence((notAhead(numberStart), notAhead(keyword), bare)).pick(2).map(
        (s: sink string) => Sym(s, false)
      )
    rawAtom = choice(
      @[bytesTok, numberTok, nilTok, text, quotedSymbol] & extensions & @[symbol]
    )
    # a bool, since an Option of the empty Nothing reads as none in the VM (Nim 2.4.0)
    marked = (ch('!') & ends).skip.map(_ => true).optional(false)
    atom = (rawAtom & marked).map(
      proc(m: sink (Node, bool)): auto =
        if m[1]:
          ! move m[0]
        else:
          move m[0]
    )

    list = delimited(ch('['), ch(']').trim(ws), form.star).map(
        (items: sink seq[Node]) => List(items, false)
      )
    record = delimited(ch('('), ch(')').trim(ws), form.plus).map(
        (items: sink seq[Node]) => Rec(items, false)
      )
    colon = ch(':').trim(ws)
    entries = ((form & colon).pick(0) & form).star
    members = form.star
    # the first member, read once, decides between a dict and a set
    braced = (form & (colon & form).pick(1).optional).callCC(
      proc(next: TextParser[(Node, Option[Node])], ctx: Context[string]): Result[Node] =
        var f = next.parseOn(ctx)
        if not f.isSuccess:
          return failedAs(Node, f)
        var (k, v) = f.take
        if v.isSome:
          var r = entries.parseOn(ctx.at(f.pos))
          if not r.isSuccess:
            return failedAs(Node, r)
          var es = r.take
          es.insert((move k, move v.get), 0)
          succeed(Dict(es), r.pos)
        else:
          var r = members.parseOn(ctx.at(f.pos))
          if not r.isSuccess:
            return failedAs(Node, r)
          var items = r.take
          items.insert(move k, 0)
          succeed(Set(items), r.pos)
    )
    emptyDict = colon.map(_ => Dict(@[], false))
    emptySet = epsilon[string, Node](Set(@[], false))
    braces = delimited(ch('{'), ch('}').trim(ws), emptyDict / braced / emptySet)
    frame = list / record / braces
    markedFrame = (ch('!') & frame).pick(1).map(
        proc(m: sink Node): auto =
          ! m
      )

  value.define(markedFrame / frame / atom)
  value

proc basslineForm*(
    extensions: seq[TextParser[Node]] = @[], reserved: seq[string] = @[]
): TextParser[Node] =
  ## One value and the space around it.
  basslineValue(extensions, reserved).trim(space())

proc basslineParser*(): TextParser[Node] =
  ## Exactly one value.
  basslineForm().complete.resolve

proc basslineDocument*(): TextParser[seq[Node]] =
  ## Any number of values, including none.
  basslineForm().star.trim(space()).complete.resolve

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

proc writeText(n: Value, dst: var string) =
  template writeMark() =
    if n.mark:
      dst.add("!")

  case n.kind
  of bNil:
    dst.add("nil")
    writeMark()
  of bNum:
    dst.add($n.vnum)
    writeMark()
  of bText:
    dst.add('"')
    dst.add(n.vstr.escaped('"'))
    dst.add('"')
    writeMark()
  of bSym:
    if n.vstr.isBareSpelling:
      dst.add n.vstr
    else:
      dst.add('\'')
      dst.add(n.vstr.escaped('\''))
      dst.add('\'')
    writeMark()
  of bBytes:
    dst.add("0x")
    dst.add(n.vstr.toHex)
    writeMark()
  of bList, bRec, bSet:
    writeMark()
    dst.add(n.kind.openChar)
    let hi = n.len - 1
    for i in 0 .. hi:
      n.member(i).asValue.writeText(dst)
      if i != hi:
        dst.add(' ')
    dst.add(n.kind.closeChar)
  of bDict:
    writeMark()
    dst.add(n.kind.openChar)
    let hi = n.len - 1
    for i in 0 .. hi:
      n.member(i).asValue.writeText(dst)
      if i != hi:
        if i mod 2 == 0:
          dst.add(": ")
        else:
          dst.add(" ")
    if n.len == 0:
      dst.add(':')
    dst.add(n.kind.closeChar)

proc toBlText*(self: Value): string =
  if self.isPure:
    self.writeText(result)
  else:
    self.reifyDeep.writeText(result)

proc toBlText*(self: Node): string =
  if self.isPure:
    self.asValue.writeText(result)
  else:
    self.reifyDeep.writeText(result)

proc `$`*(self: Value): string =
  self.toBlText

proc `$`*(self: Node): string =
  self.toBlText

proc parse*(_: typedesc[Value], s: string): Value =
  ## the one value s spells
  var r = basslineParser().parse(s)
  var read = r.take
  move read.asValue

proc parseMany*(_: typedesc[Value], s: string): seq[Value] =
  var r = basslineDocument().parse(s)
  var read = r.take
  for each in read.mitems:
    result.add move each.asValue