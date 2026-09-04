## the codec against the corpus: a decoder fed a value one byte at a
## time waits and never refuses until the last byte lands it, and
## bytes a decoder must reject are rejected however they arrive.
## Random values survive encoding, and value order is byte order.

import std/[math, unittest]
import bl/core
import bl/lib/blah
import ./corpus

suite "one byte at a time":
  filter ce, c:
    let
      name = c.items[1].text
      value = c.items[2]
      bytes = c.items[3].bytes
    test name:
      var d = newDecoder()
      var landed: seq[Value]
      for i, b in bytes:
        d.buf.add b
        for v in d.checked:
          landed.add v.toValue
        if i < bytes.high:
          check landed.len == 0
          check d.pending
      check landed.len == 1
      if landed.len == 1:
        check landed[0] == value
      check not d.pending

  filter reject, c:
    let
      name = c.items[1].text
      bytes = c.items[2].bytes
    test name:
      var d = newDecoder()
      var refused = false
      try:
        for b in bytes:
          d.buf.add b
          for v in d.checked: discard
      except CodecError:
        refused = true
      check refused

suite "random values":
  var values: seq[Value]
  for _ in 0 ..< 80:
    values.add randValue(3)

  test "encode then decode":
    for v in values:
      let l = land(ceBytes(v))
      check not l.refused
      check l.values.len == 1
      if l.values.len == 1:
        check l.values[0].toValue == v

  test "many values on one buffer":
    let enc = newEncoder()
    for v in values:
      enc.write v
    let l = land(enc.bytes)
    check not l.refused
    check not l.pending
    check l.values.len == values.len
    for i in 0 ..< min(l.values.len, values.len):
      check l.values[i].toValue == values[i]

  test "value order is byte order":
    var spelled: seq[seq[byte]]
    for v in values:
      spelled.add ceBytes(v)
    for i in 0 ..< values.len:
      for j in 0 ..< values.len:
        check cmp(values[i], values[j]).sgn == cmpBytes(spelled[i], spelled[j]).sgn
