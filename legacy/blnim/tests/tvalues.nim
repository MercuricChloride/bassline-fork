import std/[options, unittest]
import petit_parser
import bl/core
import bl/grammar/values

proc refusal(v: var Value, pass: proc (v: var Value)): string =
  ## what the pass refuses with, or nothing
  try: pass(v)
  except BasslineError as e: result = e.msg

suite "value parsers":
  test "a closure, read the way base.nim reads it by hand":
    let
      params = listOf(symbolOf().star)
      closure = recordOf(sequence((symbol"fn", params, anyValue(), dictOf(entries(anyValue(), anyValue())))))
    check closure.parse(rv"(fn [x y] (add x! y!) {:})").isSuccess
    check closure.parse(rv"(fn [x] body {a: 1})").value[1] == @["x"]
    check not closure.parse(rv"(fn x body {:})").isSuccess
    check closure.parse(rv"(fn x body {:})").message == "expected list at 1"
    check closure.parse(rv"(f [x] body {:})").message == "expected fn at 0"
    check closure.parse(rv"(fn [x 1] body {:})").message == "expected one of symbol, end of input at 1.1"
    check closure.parse(rv"x").message == "expected record at the value"

  test "kinds, marks and payloads":
    check ofKind(bSym, marked).parse(rv"go!").isSuccess
    check not ofKind(bSym, unmarked).parse(rv"go!").isSuccess
    check number().parse(rv"42").value.toInt == 42
    check textOf().parse(readValue("\"hi\"")).value == "hi"
    check bytesOf().parse(rv"0xdead").value == @[0xde'u8, 0xad]
    check nilValue().parse(rv"nil").isSuccess
    check dictOf(entries(symbolOf(), number())).parse(rv"{a: 1 b: 2}").value.len == 2

  test "the passes finish a structural value where it stands":
    var outOfOrder = Value(kind: bSet, frame: newBuffer(@[sym"b", sym"a"]))
    check outOfOrder.refusal(canonical) == "members out of canonical order at 1"
    sorted(outOfOrder)
    check outOfOrder == rv"{a b}"
    var finished = rv"{a b}"
    canonical(finished)
    check finished == rv"{a b}"
    var repeated = Value(kind: bSet, frame: newBuffer(@[sym"a", sym"a"]))
    check repeated.refusal(sorted) == "repeated member at 1"
    var badText = Value(kind: bList, frame: newBuffer(@[text("\xff")]))
    check badText.refusal(canonical) == "malformed UTF-8 in text at 0"
    var deep = Value(kind: bList, frame: newBuffer(@[num(1),
      Value(kind: bRec, frame: newBuffer(@[sym"f", Value(kind: bSet, frame: newBuffer(@[sym"b", sym"a"]))]))]))
    check deep.refusal(canonical) == "members out of canonical order at 1.1.1"
    var nested = rv"!(f [1 2] {a: {b: 1}})"
    canonical(nested)
    check nested == rv"!(f [1 2] {a: {b: 1}})"
