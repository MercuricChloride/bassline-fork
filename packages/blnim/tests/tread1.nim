import std/unittest
import blnim/misc/[read, print]

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
    check readValue("`nil") == nilValue(true)
    check readValue("nilx") == sym"nilx"

  test "numbers":
    check readValue("0") == num"0"
    check readValue("-5") == num"-5"
    check readValue("123456789012345678901234567890") ==
          num"123456789012345678901234567890"

  test "strings":
    check readValue("\"\"") == text""
    check readValue("\"hi\"") == text"hi"
    check readValue("\"a\\n\\t\\r\\\\\\\"b\"") == text("a\n\t\r\\\"b")
    check readValue("\"a\nb\"") == text("a\nb")   # literal newline is legal

  test "symbols":
    check readValue("foo") == sym"foo"
    for s in ["->", "-", "<=", "+5", "*", "a.b!"]:
      check readValue(s) == sym(s)
    check readValue("'has space'") == sym"has space"
    check readValue("''") == sym""
    check readValue("'a\\'b'") == sym"a'b"

  test "bytes":
    check readValue("#[]") == bytes(newSeq[byte]())
    check readValue("#[DEAD]") == bytes(@[byte 0xDE, 0xAD])
    check readValue("#[de ad]") == bytes(@[byte 0xDE, 0xAD])
    check readValue("#[D EA D]") == bytes(@[byte 0xDE, 0xAD])

suite "frames":
  test "lists and records":
    check readValue("[]") == list()
    check readValue("[1 two [3]]") == list(num"1", sym"two", list(num"3"))
    check readValue("(f)") == record(sym"f")
    check readValue("(f 1 nil)") == record(sym"f", num"1", nilValue())

  test "sets read in any order, mean their canonical form":
    check readValue("#{}") == values.set(newSeq[Value]())
    check readValue("#{3 1 2}") == values.set(num"1", num"2", num"3")

  test "dicts read in any order, mean their canonical form":
    check readValue("{}") == dict(newSeq[(Value, Value)]())
    check readValue("{b: 2 a: 1}") ==
          dict(@[(sym"a", num"1"), (sym"b", num"2")])
    check readValue("{foo:bar}") == dict(@[(sym"foo", sym"bar")])
    check readValue("{[1]: one}") == dict(@[(list(num"1"), sym"one")])

suite "marks":
  test "mark rides any datum":
    check readValue("`f") == mark(sym"f")
    check readValue("`(f 1)") == mark(record(sym"f", num"1"))
    check readValue("`[1]") == mark(list(num"1"))
    check readValue("`#[AB]") == mark(bytes(@[byte 0xAB]))
    check readValue("[`a b]") == list(mark(sym"a"), sym"b")
    check readValue("{`k: 1}") == dict(@[(mark(sym"k"), num"1")])

  test "mark must immediately prefix its value":
    check rejects("` f")
    check rejects("``f")
    check rejects("`")
    check rejects("`)")
    check rejects("`;c\nf")

suite "rejections":
  test "non-canonical numbers":
    for s in ["007", "-0", "1.5", "42px", "1-2", "1."]:
      check rejects(s)

  test "malformed frames":
    check rejects("()")               # record with no head
    check rejects("#{1 1}")           # duplicate set member
    check rejects("{a: 1 a: 2}")      # duplicate dict key
    check rejects("{a 1}")            # missing colon
    check rejects("{a:}")             # missing value
    check rejects("[1")
    check rejects("(")
    check rejects("a : b")            # ':' outside a dict

  test "malformed bytes":
    check rejects("#[AB")
    check rejects("#[ABC]")
    check rejects("#[XY]")
    check rejects("#x")
    check rejects("#")

  test "malformed scalars":
    check rejects("\"ab")
    check rejects("'ab")
    check rejects("\"a\\x\"")         # unknown escape
    check rejects("\"\xFF\"")         # ill-formed UTF-8
    check rejects("\xFF")

  test "stray closers":
    for s in [")", "]", "}", ":"]:
      check rejects(s)

suite "documents":
  test "a document is any number of values":
    check readDocument("").len == 0
    check readDocument(" ,, ; only noise\n").len == 0
    check readDocument("1 2 3") == @[num"1", num"2", num"3"]
    check readDocument("; hi\n1 ; trailing\n2") == @[num"1", num"2"]
    check readValue("[1, 2]") == list(num"1", num"2")

  test "readValue wants exactly one":
    expect ReadError:
      discard readValue("")
    expect ReadError:
      discard readValue("1 2")

suite "print and read are inverse":
  test "round trip":
    let corpus = [
      nilValue(), nilValue(true), num"0", num"-42",
      num"123456789012345678901234567890",
      text"", text("line\nbreak\ttab \"q\" \\ back"),
      sym"plain", sym"has space", sym"nil", sym"", sym"007", sym"-5",
      sym"a:b", sym"#weird", sym"`tick", sym"a'b", mark(sym"go"),
      bytes(newSeq[byte]()), bytes(@[byte 0, 255]),
      list(), values.set(newSeq[Value]()),
      dict(newSeq[(Value, Value)]()),
      record(sym"f", nilValue()),
      dict(@[(num"1", text"one"), (list(num"2"), text"two")]),
      mark(record(sym"run",
        list(num"1", mark(sym"x")),
        values.set(sym"b", sym"a"),
        dict(@[(sym"k", bytes(@[byte 0xEE]))])))
    ]
    for v in corpus:
      check readValue($v) == v
