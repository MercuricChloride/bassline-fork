## the JSON dialect: a value travels losslessly, kind-tagged, and a
## record that is not a value is refused, never coerced

import std/unittest
import bl/core
import bl/lib/[json, blah, blmacro]
import ./corpus

template survives(v: untyped) =
  check bl(v).toJson.toValue == bl(v)

template refused(j: string) =
  expect JsonRefusal:
    discard parseJson(j).toValue

suite "round trips":
  test "every kind, marked and not":
    survives nil
    survives !nil
    survives 42
    survives !(-7)
    survives "text"
    survives !"text"
    survives sym
    survives !sym
    survives x"dead_beef"
    survives x""
    survives [1, [2], {3}]
    survives ![]
    survives f(a, !b)
    survives {a: 1, [b]: {c: d}}
    survives {:}
    survives {1, 2, !3}
    survives {}
  test "past int64 travels as a raw number":
    let w = bl(n"123456789012345678901234567890")
    check $w.toJson["value"] == "123456789012345678901234567890"
    check w.toJson.toValue == w
    check bl(!n"-123456789012345678901234567890").toJson.toValue == bl(!n"-123456789012345678901234567890")
  test "every corpus case":
    for c in cases:
      check c.toJson.toValue == c
  test "random values":
    for _ in 0 ..< 100:
      let v = randValue(3)
      check v.toJson.toValue == v

suite "refusals":
  test "the record must be a kind-tagged object":
    refused "42"
    refused "{}"
    refused """{"kind": 5}"""
    refused """{"kind": "float", "value": 1.5}"""
    refused """{"kind": "number"}"""
    refused """{"kind": "nil", "value": 1}"""
    refused """{"kind": "number", "value": 1, "mark": 1}"""
  test "a quoted number is a string, not a number":
    refused """{"kind": "number", "value": "123"}"""
    refused """{"kind": "number", "value": 1.5}"""
  test "text must be UTF-8":
    refused "{\"kind\": \"text\", \"value\": \"\xFF\"}"
  test "bytes are a 0x hex string":
    refused """{"kind": "bytes", "value": "dead"}"""
    refused """{"kind": "bytes", "value": "0xdea"}"""
    refused """{"kind": "bytes", "value": 1}"""
  test "a record needs a head":
    refused """{"kind": "record", "value": []}"""
    refused """{"kind": "record", "value": 1}"""
  test "a dict is pairs with distinct keys":
    refused """{"kind": "dict", "value": {}}"""
    refused """{"kind": "dict", "value": [[{"kind": "symbol", "value": "a"}]]}"""
    refused """{"kind": "dict", "value": [
      [{"kind": "symbol", "value": "a"}, {"kind": "number", "value": 1}],
      [{"kind": "symbol", "value": "a"}, {"kind": "number", "value": 2}]]}"""
