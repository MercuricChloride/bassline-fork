import std/[unittest]
import bl/core
import bl/lib/blah

suite "ordering":

  test "simple total order":
    let values = [
      null(),
      num(123),
      text"foo",
      sym"foo",
      bytes("foo".toBytes),
      initList(),
      initRec sym"foo",
      initDict(),
      initSet()
    ]
    for i in 1..<values.len:
      check values[i - 1] < values[i]

  test "shortlex for atoms":
    check num(9) < num(10)
    check num(1) < num(-1)
    check num(-1) < num(-2)
    check text("z") < text("aa")

  test "a frame sorts after the longer frame it prefixes":
    check initList(@[num 1, num 2]) < initList(@[num 1])
    check initList(@[num 1, num 2]) < initList(@[num 2])
    check initRec(@[sym"f", num 1]) < initRec(@[sym"f"])
    check initList() > initList(@[num 1])

suite "encodings":

  test "round trips":
    var
      encoder = newEncoder()
      decoder = newDecoder()
      vals: seq[Value]
    
    for val in blah 10:
      encoder.write val
      vals.add val

    echo "encoded: ", (encoder.buf.data.len / 1_000_000), " mb"
    decoder.buf.add encoder.bytes
    
    var i = 0
    for val in decoder:
      check vals[i] == val.toValue()
      inc i
    require i == vals.len