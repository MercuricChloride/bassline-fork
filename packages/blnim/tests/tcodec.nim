## the codec against the corpus: a decoder fed a value one byte at a
## time waits and never refuses until the last byte lands it, and
## bytes a decoder must reject are rejected however they arrive.
## Random values survive encoding, alone and concatenated.

import std/unittest
from std/sequtils import repeat
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
      expect CodecError:
        for b in bytes:
          d.buf.add b
          for v in d.checked: discard

suite "value size cap":
  const cap = 4096
  proc decoded(bytes: openArray[byte]): seq[Value] =
    var d = newDecoder(maxValueBytes = cap)
    d.buf.add bytes
    for v in d.checked: result.add v.toValue

  test "a scalar header over the cap is refused before any payload":
    let full = ce(bytes(newSeq[byte](cap + 1)))
    let header = full[0 ..< full.len - cap - 1]      # no payload behind it
    expect CodecError: discard decoded(header)

  test "a frame that never closes is refused once it holds over the cap":
    let stream = ce(initList())[0 ..< ^1] & # a list header, no END
                 repeat(ce(null())[0], cap) # one-byte members, over the cap
    expect CodecError: discard decoded(stream)

  test "a value at the cap decodes":
    let v = bytes(newSeq[byte](cap div 2))
    check decoded(ce(v)) == @[v]

suite "random values":
  var values: seq[Value]
  for _ in 0 ..< 80:
    values.add randValue(3)

  test "encode then decode":
    for v in values:
      let l = land(v.ce)
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
