## Value: cmp is CE order, and Num holds every integer

import std/[math, unittest]
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

  test "value order is byte order":
    var values: seq[Value]
    for _ in 0 ..< 80:
      values.add randValue(3)
    var spelled: seq[seq[byte]]
    for v in values:
      spelled.add v.ce
    for i in 0 ..< values.len:
      for j in 0 ..< values.len:
        check cmp(values[i], values[j]).sgn == cmpBytes(spelled[i], spelled[j]).sgn

suite "numbers":

  test "a spelling that fits int64 is an int":
    check initNum("42").isInt
    check initNum("-9223372036854775808").isInt
    check initNum("9223372036854775807").isInt
    check initNum("42").toInt == 42

  test "past int64 is held as spelled":
    check initNum("9223372036854775808").isWide
    check initNum("-9223372036854775809").isWide
    check $initNum("123456789012345678901234567890") == "123456789012345678901234567890"
    expect ValueError:
      discard initNum("9223372036854775808").toInt

  test "only a canonical spelling is a number":
    for s in ["007", "-0", "1_000", "", "-", "abc", "12x", "1.5"]:
      checkpoint(s)
      expect ValueError:
        discard initNum(s)

  test "wide and int compare as their spellings":
    let two63 = num("9223372036854775808")
    check num(int.high) < two63          # both nineteen digits
    check two63 < num(int.low)           # twenty digits with the sign
    check num("99999999999999999999") > num(1000000000000000000)
    check num("-99999999999999999999") > num("99999999999999999999")
    check num("123456789012345678901234567890") == num("123456789012345678901234567890")
