import std/[options, os, unittest]
import petit_parser
import bl/core
import bl/grammar/[bassline_text, values]

let
  make = makeValues()
  one = basslineParser(make)
  doc = basslineDocument(make)
  corpusText = readFile(currentSourcePath.parentDir / ".." / ".." / ".." / "corpus" / "corpus.bl")
  cases = readDocument(corpusText)   # the hand written reader is the oracle

proc head(c: Value): string =
  if c[0].isKind(bSym): c[0].text else: ""

proc finished(text: string): Option[Value] =
  ## the grammar, then the pass
  var r = one.parse(text)
  if not r.isSuccess: return none Value
  var v = r.take
  try:
    sorted(v)
    some v
  except BasslineError:
    none Value

proc refusal(text: string): string =
  ## what the pass refuses the text's structural value with
  var v = one.parse(text).value
  try: sorted(v)
  except BasslineError as e: result = e.msg

suite "bassline text as a grammar":
  test "the corpus reads as a document":
    let r = doc.parse(corpusText)
    check r.isSuccess and r.value.len == 150

  test "reads cases read as the reader reads them":
    var seen = 0
    for c in cases:
      if c.head == "reads":
        check finished(c[1].text) == some c[2]
        inc seen
    check seen == 17

  test "refuses and incomplete cases fail, in the grammar or the pass":
    var seen = 0
    for c in cases:
      if c.head in ["refuses", "incomplete"]:
        check finished(c[1].text).isNone
        inc seen
    check seen == 42

  test "document cases read as the reader reads them":
    for c in cases:
      if c.head == "document":
        let r = doc.parse(c[1].text)
        check r.isSuccess
        var got = r.value
        for v in got.mitems: sorted(v)
        check got == readDocument(c[1].text)

  test "spellings are normalised":
    check finished("0xDE_AD") == some bytes(@[0xde'u8, 0xad])
    check finished("-1_000") == some num(-1000)
    check finished("9223372036854775808") == some num("9223372036854775808")
    check finished("'a\\'b\\n'") == some sym("a'b\n")
    check finished("\"say \\\"hi\\\"\"") == some text("say \"hi\"")

  test "marks":
    check finished("!{a: 1}").get.mark
    check not finished("{a: 1}").get.mark
    let r = finished("(f go! !(g) \"s\"! 0x!)").get
    check r[1].mark and r[2].mark and r[3].mark and r[4].mark
    check not r[0].mark
    check r[4].isKind(bBytes) and r[4].bytes.len == 0

  test "the pass sorts, and refuses repeats":
    check finished("{b a}") == some rv"{a b}"
    check finished("{b: 1 a: 2}") == some rv"{a: 2 b: 1}"
    check refusal("{a a}") == "repeated member at 1"
    check refusal("{a: 1 a: 2}") == "repeated key at 2"
    check refusal("[1 {a: {x y x}}]") == "repeated member at 1.1.2"

  test "both paths agree":
    for input in ["[1 2", "{a: 1 a: 2}", "(f go! !(g))", "0x123", "-0", "a!b", "; c\n5"]:
      check one.accepts(input) == one.parse(input).isSuccess
    for n in one.allParsers:
      check not (n of SettableParser[string, Value])
