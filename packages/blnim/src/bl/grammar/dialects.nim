## The bassline textual syntax with dialect blocks. `lang NAME [[ … ]]`
## reads the block with the parser registered as NAME, so a dialect's own
## notation stands where a value would and reads as values. The block is
## a Lua long bracket, `[=[ … ]=]` at any level, for content holding `]]`.
## A dialect parser is used as given: resolve it, and let it read the
## whole block. Everything builds through the same `Make` as the text.

import std/[sequtils, strutils, sugar, tables]
import petit_parser
import petit_parser/grammar/[sexp, json]
import ../core
import ./[bassline_text, uri]
export text

type Dialects*[V] = Table[string, TextParser[V]]

proc langForm[V](dialects: Dialects[V]): TextParser[V] =
  let
    gap = space().star.skip
    ends = notAhead(noneOf(Delims, "symbol character"))
    name = noneOf(Delims, "symbol character").plus.flatten("a dialect name")
    opener = sequence((str("lang"), ends, gap, position[string](), name, gap,
                       ch('['), ch('=').star.flatten, ch('[')))
      .map(m => (m[3], m[4], m[7].len))
    unknown = failure[string, V]("a known dialect")
    unfinished = failure[string, V]("the end of the block")
  opener.callCC(
    proc (next: TextParser[(int, string, int)], ctx: Context[string]): Result[V] =
      var o = next.parseOn(ctx)
      if not o.isSuccess: return failedAs(V, o)
      let
        (at, name, level) = o.take
        close = "]" & '='.repeat(level) & "]"
        input = ctx.input
        stop = input.source.find(close, o.pos, input.stop - 1)
      if stop < 0: return fail[string, V](failure[string, V]("'" & close & "'"), ctx.at(input.stop))
      let dialect = dialects.getOrDefault(name)
      if dialect.isNil: return fail[string, V](unknown, ctx.at(at))
      let outer = input.stop
      input.stop = stop
      defer: input.stop = outer
      var r = dialect.parseOn(ctx.at(o.pos))
      if not r.isSuccess: r
      elif r.pos < stop: fail[string, V](unfinished, ctx.at(r.pos))
      else: succeed(r.take, stop + close.len))

proc extendedValue*[V](make: Make[V], dialects: Dialects[V]): TextParser[V] =
  ## One value, bare.
  basslineValue(make, @[langForm(dialects)], @["lang"])

proc extendedForm*[V](make: Make[V], dialects: Dialects[V]): TextParser[V] =
  ## One value and the space around it.
  extendedValue(make, dialects).trim(space())

proc extendedParser*[V](make: Make[V], dialects: Dialects[V]): TextParser[V] =
  ## Exactly one value.
  extendedForm(make, dialects).complete.resolve

proc extendedDocument*[V](make: Make[V], dialects: Dialects[V]): TextParser[seq[V]] =
  ## Any number of values, including none.
  extendedForm(make, dialects).star.trim(space()).complete.resolve

# Two dialects from petit-parser's own grammars, and the reference one

proc sexpNode[V](make: Make[V], s: Sexp): V =
  let n = case s.kind
    of skSymbol: make.atom(bSym, s.stringVal, false)
    of skString: make.atom(bText, s.stringVal, false)
    of skNumber: make.atom(bNum, $s.numberVal, false)
    of skList: make.frame(bList, s.listVal.map((x: Sexp) => sexpNode(make, x)), false)
  if s.quoted: make.frame(bRec, @[make.atom(bSym, "quote", false), n], false) else: n

proc sexpDialect*[V](make: Make[V]): TextParser[V] =
  ## Symbols, numbers, text and lists as themselves, `'x` as `(quote x)`.
  sexpParser().map((s: Sexp) => sexpNode(make, s))

proc jsonNode[V](make: Make[V], j: JsonValue): V =
  case j.kind
  of jkNull: make.atom(bNil, "", false)
  of jkBool: make.atom(bSym, $j.boolVal, false)
  of jkString: make.atom(bText, j.stringVal, false)
  of jkNumber: make.atom(bNum, j.numberVal, false)
  of jkArray: make.frame(bList, j.arrayVal.map((x: JsonValue) => jsonNode(make, x)), false)
  of jkObject:
    var members: seq[V]
    for k, v in j.objectVal.pairs:
      members.add make.atom(bText, k, false)
      members.add jsonNode(make, v)
    make.frame(bDict, members, false)

proc integral(j: JsonValue): bool =
  case j.kind
  of jkNumber: j.numberVal.allCharsInSet(Digits + {'-'})
  of jkArray: j.arrayVal.all(integral)
  of jkObject: j.objectVal.values.toSeq.all(integral)
  else: true

proc jsonDialect*[V](make: Make[V]): TextParser[V] =
  ## null is nil, true and false are symbols, strings are text, arrays
  ## are lists and objects are dicts keyed by text. A number that is not
  ## an integer is refused.
  jsonParser().where(integral, "integers only").map((j: JsonValue) => jsonNode(make, j))

proc standardDialects*[V](make: Make[V]): Dialects[V] =
  {"sexp": sexpDialect(make), "json": jsonDialect(make), "uri": uriParser(make)}.toTable
