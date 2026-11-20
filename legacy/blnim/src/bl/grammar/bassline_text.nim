## The bassline textual syntax (data-model.org, "Textual Syntax") as a
## grammar that builds whatever `Make` builds: values whose sets and dicts
## hold their members in written order, for the pass in `values` to sort
## and check, or plain objects for the editor. Numbers are kept as spelled
## with the `_` separators removed, bytes as bytes, text and symbols
## decoded. Only the syntax is checked here. Repeats and encodings are the
## pass's business.

import std/[sequtils, strutils, sugar]
import petit_parser
import ../core/shared/shared

type Make*[V] = object
  ## how a grammar builds its result: an atom from its payload, a frame
  ## from its members in order, a dict's as keys and values alternating,
  ## and a value marked after the fact. Each is handed what it is given
  ## to keep, so nothing the grammar built is copied on the way.
  atom*: (k: Kind, payload: sink string, mark: bool) -> V
  bytes*: (b: sink seq[byte], mark: bool) -> V
  frame*: (k: Kind, members: sink seq[V], mark: bool) -> V
  mark*: (v: sink V) -> V

const Delims* = " \t\n\r[]{}():'\";!"

proc unescaped(c: char): string =
  case c
  of 'n': "\n"
  of 't': "\t"
  of 'r': "\r"
  else: $c

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

proc basslineValue*[V](make: Make[V], extensions: seq[TextParser[V]] = @[],
                       reserved: seq[string] = @[]): TextParser[V] =
  ## One value, bare. `extensions` are tried before a symbol, and the
  ## `reserved` words are never read as one.
  let
    ws = space()
    value = undefined[string, V]("value")
    form = value.trim(ws)
    ends = notAhead(noneOf(Delims, "symbol character"))

    hex = chars(HexDigits, "hex digit")
    hexBody = (hex & (ch('_').optional & hex).star).skip.optional
    bytesTok = sequence((str("0x"), hexBody, ends)).flatten("bytes")
      .where(b => (b.len - 2 - b.count('_')) mod 2 == 0, "an even count of hex digits")
      .map(b => make.bytes(parseHexStr(b[2 .. ^1].replace("_", "")).toByteSeq, false))
    numberStart = digit().skip / (ch('-') & digit()).skip
    digits = ch('0').skip / (between('1', '9') & (ch('_').optional & digit()).star).skip
    numberTok = sequence((ch('-').optional, digits, ends)).flatten("number")
      .where(n => n != "-0", "a number")
      .map(n => make.atom(bNum, n.replace("_", ""), false))
    nilTok = (str("nil") & ends).map(_ => make.atom(bNil, "", false))
    text = quoted('"').map((s: sink string) => make.atom(bText, s, false))
    quotedSymbol = quoted('\'').map((s: sink string) => make.atom(bSym, s, false))
    bare = noneOf(Delims, "symbol character").plus.flatten("symbol")
    keyword = choice(reserved.map(w => (str(w) & ends).skip("'" & w & "'")))
    symbol = sequence((notAhead(numberStart), notAhead(keyword), bare)).pick(2)
      .map((s: sink string) => make.atom(bSym, s, false))
    rawAtom = choice(@[bytesTok, numberTok, nilTok, text, quotedSymbol] & extensions & @[symbol])
    atom = (rawAtom & (ch('!') & ends).skip.optional)
      .map((m: sink (V, Option[Nothing])) => (if m[1].isSome: make.mark(move m[0]) else: move m[0]))

    list = delimited(ch('['), ch(']').trim(ws), form.star)
      .map((items: sink seq[V]) => make.frame(bList, items, false))
    record = delimited(ch('('), ch(')').trim(ws), form.plus)
      .map((items: sink seq[V]) => make.frame(bRec, items, false))
    colon = ch(':').trim(ws)
    entries = ((form & colon).pick(0) & form).star
    members = form.star
    # the first member, read once, decides between a dict and a set
    braced = (form & (colon & form).pick(1).optional).callCC(
      proc (next: TextParser[(V, Option[V])], ctx: Context[string]): Result[V] =
        var f = next.parseOn(ctx)
        if not f.isSuccess: return failedAs(V, f)
        var (k, v) = f.take
        if v.isSome:
          var r = entries.parseOn(ctx.at(f.pos))
          if not r.isSuccess: return failedAs(V, r)
          var es = r.take
          es.insert((move k, v.get), 0)
          succeed(make.frame(bDict, flat(es), false), r.pos)
        else:
          var r = members.parseOn(ctx.at(f.pos))
          if not r.isSuccess: return failedAs(V, r)
          var items = r.take
          items.insert(move k, 0)
          succeed(make.frame(bSet, items, false), r.pos))
    emptyDict = colon.map(_ => make.frame(bDict, @[], false))
    emptySet = epsilon[string, V](make.frame(bSet, @[], false))
    braces = delimited(ch('{'), ch('}').trim(ws), emptyDict / braced / emptySet)
    frame = list / record / braces
    markedFrame = (ch('!') & frame).pick(1).map(make.mark)

  value.define(markedFrame / frame / atom)
  value

proc basslineForm*[V](make: Make[V], extensions: seq[TextParser[V]] = @[],
                      reserved: seq[string] = @[]): TextParser[V] =
  ## One value and the space around it.
  basslineValue(make, extensions, reserved).trim(space())

proc basslineParser*[V](make: Make[V]): TextParser[V] =
  ## Exactly one value.
  basslineForm(make).complete.resolve

proc basslineDocument*[V](make: Make[V]): TextParser[seq[V]] =
  ## Any number of values, including none.
  basslineForm(make).star.trim(space()).complete.resolve
