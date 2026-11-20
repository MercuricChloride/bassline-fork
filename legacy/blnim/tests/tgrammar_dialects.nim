import std/[os, sugar, tables, unittest]
import petit_parser
import bl/core
import bl/grammar/[dialects, values]

let make = makeValues()

proc words(): TextParser[Value] =
  word().plus.flatten("word").map((w: string) => make.atom(bSym, w, false)).trim.star
    .map((ws: seq[Value]) => make.frame(bList, ws, false))

var registry = standardDialects(make)
registry["words"] = words()

let
  one = extendedParser(make, registry)
  doc = extendedDocument(make, registry)

proc reads(text: string): Value =
  result = one.parse(text).value
  sorted(result)

suite "dialect blocks":
  test "a block reads with its dialect":
    check reads("lang sexp [[ (a 1 \"x\") ]]") == rv"""[a 1 "x"]"""
    check reads("lang words [[ hello world ]]") == rv"[hello world]"

  test "blocks stand where values do":
    check reads("""(q lang json [[ {"b": [1, 2], "a": null} ]] lang sexp [[ 'x ]]!)""") ==
      rv"""(q {"a": nil "b": [1 2]} !(quote x))"""

  test "long brackets hold the shorter close":
    check reads("lang sexp [=[ \"]]\" ]=]") == rv""""]]""""

  test "lang is reserved":
    check reads("language") == rv"language"
    check reads("'lang'") == sym"lang"
    check not one.parse("lang").isSuccess

  test "failures":
    check one.parse("lang nope [[ x ]]").message == "expected a known dialect at 1:6"
    check one.parse("lang sexp [[ (a").message == "expected ']]' at 1:16"
    check one.parse("lang words [[ hello, world ]]").message ==
      "expected one of word, the end of the block at 1:20"
    check one.parse("lang json [[ 1.5 ]]").message == "expected integers only at 1:18"
    check one.parse("lang sexp [[ (a ]]").message == "expected one of ''', '(', '\"', atom, ')' at 1:17"

  test "the corpus still reads":
    let corpus = doc.parse(readFile(currentSourcePath.parentDir / ".." / ".." / ".." / "corpus" / "corpus.bl"))
    check corpus.isSuccess and corpus.value.len == 150

  test "both paths agree":
    for input in ["lang sexp [[ (a) ]]", "lang nope [[ x ]]", "[lang words [[ a b ]] 1]", "lang"]:
      check one.accepts(input) == one.parse(input).isSuccess
