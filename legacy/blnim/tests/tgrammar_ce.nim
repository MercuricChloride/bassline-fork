import std/[os, unittest]
import petit_parser
import bl/grammar/[bassline_ce, values]
import bl/core


let
  corpusPath = currentSourcePath() / "../../../../corpus/"
  make = makeValues()
  one = ceParser(make)
  cases = readFile(corpusPath / "corpus.bl").readDocument
  structural = ["invalid-tag", "end-with-bits", "end-at-top", "stranded-key", "length-bits",
                "bad-integer", "empty-record", "non-minimal-length"]

proc head(c: Value): string =
  if c[0].isKind(bSym): c[0].text else: ""

proc finished(data: seq[byte]): Option[Value] =
  var r = one.parse(data)
  if not r.isSuccess: return none Value
  var v = r.take
  try:
    canonical(v)
    some v
  except BasslineError:
    none Value

proc refused(v: var Value): bool =
  try:
    canonical(v)
    false
  except BasslineError:
    true

suite "canonical encoding as a grammar":
  test "the corpus reads as a document":
    let r = ceDocument(make).parse(readFile(corpusPath / "corpus.blb").toByteSeq)
    check r.isSuccess and r.value.len == 150

  test "ce cases decode to their value":
    var seen = 0
    for c in cases:
      if c.head == "ce":
        check finished(c[3].bytes) == some c[2]
        inc seen
    check seen == 53

  test "starved input fails in the grammar":
    var seen = 0
    for c in cases:
      if c.head == "starved":
        check not one.parse(c[2].bytes).isSuccess
        inc seen
    check seen == 6

  test "rejects fall to the grammar or to the pass by reason":
    for c in cases:
      if c.head == "reject":
        var r = one.parse(c[2].bytes)
        if c[3].text in structural:
          check not r.isSuccess
        else:
          check r.isSuccess
          var v = r.take
          check v.refused

  test "lengths in every form":
    check one.parse("\x33abc".toByteSeq).value.text == "abc"
    check one.parse("\x37\x08abcdefgh".toByteSeq).value.text == "abcdefgh"
    check one.parse("\x37\xff\x00\x00\x01\x00".toByteSeq & newSeq[byte](256)).value.text.len == 256
    check one.parse("\x5a\xde\xad".toByteSeq).value.bytes == @[0xde'u8, 0xad]
    check one.parse("\x5a\xde\xad".toByteSeq).value.mark
    check one.parse("\x37\x08abc".toByteSeq).message == "expected a whole payload at 2"
    check one.parse("\x37\x03abc".toByteSeq).message == "expected a minimal length at 1"
    check one.parse("\x00".toByteSeq).message == "expected a value header at 0"
    check one.parse("\x61\xa0".toByteSeq).message == "expected a value header at 0"

  test "both paths agree":
    for input in ["\x60\x21\x31\xa0", "\x60\x21", "\x80\x41\x61\xa0", "", "\xa0"]:
      check one.accepts(input.toByteSeq) == one.parse(input.toByteSeq).isSuccess
    for n in one.allParsers:
      check not (n of SettableParser[seq[byte], Value])
