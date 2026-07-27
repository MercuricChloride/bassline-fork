import std/unittest
import pkg/core
import pkg/lib/[read, print]

proc rejects(text: string): bool =
  try:
    discard readDocument(text)
    false
  except ReadError:
    true

suite "atoms":
  test "nil is reserved, quotable, markable":
    check readValue("nil") == nilValue()
    check readValue("'nil'") == sym"nil"
    check readValue("nil!") == nilValue(true)
    check readValue("nilx") == sym"nilx"

  test "numbers":
    check readValue("0") == num"0"
    check readValue("-5") == num"-5"
    check readValue("123456789012345678901234567890") ==
      num"123456789012345678901234567890"

  test "'_' groups digits and never survives the reading":
    check readValue("1_000_000") == num"1000000"
    check readValue("-1_000") == num"-1000"
    check $readValue("1_000") == "1000"
    check readValue("_5") == sym"_5" # no digit in front of it: a symbol
    check rejects("1_")
    check rejects("1__000")
    check rejects("_5_") == false # still that symbol
    check rejects("0_0") # canonicality is judged on the digits

  test "strings":
    check readValue("\"\"") == text""
    check readValue("\"hi\"") == text"hi"
    check readValue("\"a\\n\\t\\r\\\\\\\"b\"") == text("a\n\t\r\\\"b")
    check readValue("\"a\nb\"") == text("a\nb") # literal newline is legal

  test "symbols":
    check readValue("foo") == sym"foo"
    for s in ["->", "-", "<=", "+5", "*", "?", "a.b", ",", "a,b", "#", "#weird", "`tick"]:
      check readValue(s) == sym(s)
    check readValue("'has space'") == sym"has space"
    check readValue("''") == sym""
    check readValue("'a\\'b'") == sym"a'b"
    check readValue("'a!b'") == sym"a!b" # '!' delimits, so it is quoted

  test "bytes":
    check readValue("0x") == bytes(newSeq[byte]())
    check readValue("0xdead") == bytes(@[byte 0xDE, 0xAD])
    check readValue("0xDEAD") == bytes(@[byte 0xDE, 0xAD]) # either case reads
    check readValue("0xde_ad") == bytes(@[byte 0xDE, 0xAD])
    check readValue("0xd_e_a_d") == bytes(@[byte 0xDE, 0xAD])

suite "frames":
  test "lists and records":
    check readValue("[]") == list()
    check readValue("[1 two [3]]") == list(num"1", sym"two", list(num"3"))
    check readValue("(f)") == record(sym"f")
    check readValue("(f 1 nil)") == record(sym"f", num"1", nilValue())

  test "braces without ':' are a set, in canonical order":
    check readValue("{}") == values.set(newSeq[Value]())
    check readValue("{3 1 2}") == values.set(num"1", num"2", num"3")
    check readValue("{lone}") == values.set(sym"lone")

  test "braces with ':' are a dict, in canonical order":
    check readValue("{:}") == dict(newSeq[(Value, Value)]())
    check readValue("{b: 2 a: 1}") == dict(@[(sym"a", num"1"), (sym"b", num"2")])
    check readValue("{foo:bar}") == dict(@[(sym"foo", sym"bar")])
    check readValue("{[1]: one}") == dict(@[(list(num"1"), sym"one")])

  test "the first element decides which":
    check rejects("{a b: c}") # a ':' in a set
    check rejects("{a: 1 b}") # an entry without ':'
    check rejects("{: a}") # '{:' is the empty dict and closes right away

suite "marks":
  test "an atom is marked behind":
    check readValue("go!") == mark(sym"go")
    check readValue("5!") == mark(num"5")
    check readValue("\"hi\"!") == mark(text"hi")
    check readValue("'has space'!") == mark(sym"has space")
    check readValue("0xab!") == mark(bytes(@[byte 0xAB]))
    check readValue("[go! stop]") == list(mark(sym"go"), sym"stop")
    check readValue("{go!: 1}") == dict(@[(mark(sym"go"), num"1")])

  test "a frame is marked in front":
    check readValue("!(f 1)") == mark(record(sym"f", num"1"))
    check readValue("![1]") == mark(list(num"1"))
    check readValue("!{a}") == mark(values.set(sym"a"))
    check readValue("!{a: 1}") == mark(dict(@[(sym"a", num"1")]))
    check readValue("!{:}") == mark(dict(newSeq[(Value, Value)]()))
    check readValue("(f go! !(g))") ==
      record(sym"f", mark(sym"go"), mark(record(sym"g")))

  test "the mark touches its value, on its side":
    check rejects("! (f)")
    check rejects("!!(f)")
    check rejects("!")
    check rejects("!x") # an atom is marked behind
    check rejects("(f)!") # a frame is marked in front
    check rejects("!(f)!")
    check rejects("go !") # a separated '!' is not a suffix
    check rejects("a!b") # a marked atom ends at a delimiter
    check rejects("!;c\n(f)")

suite "rejections":
  test "non-canonical numbers":
    for s in ["007", "-0", "1.5", "42px", "1-2", "1."]:
      check rejects(s)

  test "malformed frames":
    check rejects("()") # record with no head
    check rejects("{1 1}") # duplicate set member
    check rejects("{a: 1 a: 2}") # duplicate dict key
    check rejects("{a:}") # missing value
    check rejects("[1")
    check rejects("(")
    check rejects("a : b") # ':' outside a dict

  test "malformed bytes":
    check rejects("0xabc") # odd count of digits
    check rejects("0xzz")
    check rejects("0x_ab")
    check rejects("0xab_")
    check rejects("0XAB") # the prefix is 0x, so this is a broken number

  test "malformed scalars":
    check rejects("\"ab")
    check rejects("'ab")
    check rejects("\"a\\x\"") # unknown escape
    check rejects("\"\xFF\"") # ill-formed UTF-8
    check rejects("\xFF")

  test "stray closers":
    for s in [")", "]", "}", ":"]:
      check rejects(s)

suite "documents":
  test "a document is any number of values":
    check readDocument("").len == 0
    check readDocument(" ; only noise\n").len == 0
    check readDocument("1 2 3") == @[num"1", num"2", num"3"]
    check readDocument("; hi\n1 ; trailing\n2") == @[num"1", num"2"]

  test "a comma is an ordinary symbol character":
    check readValue("[a, b]") == list(sym"a,", sym"b")
    check rejects("[1, 2]") # '1,' is no number

  test "readValue wants exactly one":
    expect ReadError:
      discard readValue("")
    expect ReadError:
      discard readValue("1 2")

suite "print and read are inverse":
  test "the printer's own spellings":
    check $mark(sym"go") == "go!"
    check $mark(record(sym"f", num"1")) == "!(f 1)"
    check $bytes(@[byte 0xDE, 0xAD]) == "0xdead"
    check $values.set(num"3", num"1") == "{1 3}"
    check $dict(newSeq[(Value, Value)]()) == "{:}"
    check $values.set(newSeq[Value]()) == "{}"

  test "round trip":
    let corpus = [
      nilValue(),
      nilValue(true),
      num"0",
      num"-42",
      num"123456789012345678901234567890",
      mark(num"7"),
      text"",
      text("line\nbreak\ttab \"q\" \\ back"),
      mark(text"do"),
      sym"plain",
      sym"has space",
      sym"nil",
      sym"",
      sym"007",
      sym"-5",
      sym"a:b",
      sym"a!b",
      sym"a,b",
      sym"#weird",
      sym"`tick",
      sym"a'b",
      mark(sym"go"),
      bytes(newSeq[byte]()),
      bytes(@[byte 0, 255]),
      mark(bytes(@[byte 0xAB])),
      list(),
      mark(list()),
      values.set(newSeq[Value]()),
      mark(values.set(newSeq[Value]())),
      dict(newSeq[(Value, Value)]()),
      mark(dict(newSeq[(Value, Value)]())),
      record(sym"f", nilValue()),
      dict(@[(num"1", text"one"), (list(num"2"), text"two")]),
      dict(@[(mark(sym"k"), num"1")]),
      values.set(mark(sym"b"), mark(sym"a")),
      mark(
        record(
          sym"run",
          list(num"1", mark(sym"x")),
          values.set(sym"b", sym"a"),
          dict(@[(sym"k", bytes(@[byte 0xEE]))]),
        )
      ),
    ]
    for v in corpus:
      check readValue($v) == v
