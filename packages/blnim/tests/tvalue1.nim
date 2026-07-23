import std/unittest
import std/sequtils
import std/tables
import std/sets
from std/strutils import repeat, join
from std/math import sgn
import blnim/codec
import blnim/misc/[print, hash]

func roundTrips(v: Value): bool =
  decode(encode(v)) == v

proc rejects(bs: seq[byte]): bool =
  try:
    discard decode(bs)
    false
  except DecodeError:
    true

suite "round trip":
  test "scalars":
    for v in [
      nilValue(),
      nilValue(true),
      num"0",
      num"-123",
      text"",
      text"hi",
      sym"x",
      mark(sym"f"),
      bytes(@[byte 1, 2, 3]),
    ]:
      check roundTrips v

  test "frames":
    let v = record(
      sym"h",
      list(num"1", text"two"),
      set(num"3", num"1"),
      dict(@[(sym"a", num"1"), (sym"b", num"2")]),
      mark(list(sym"q")),
    )
    check roundTrips v
    check roundTrips list()
    check roundTrips set(newSeq[Value]())

  test "length tier boundaries":
    for n in [0, 1, 6, 7, 8, 254, 255, 256, 70_000]:
      check roundTrips text(newSeqWith(n, 'a').join)
      check roundTrips bytes(newSeqWith(n, byte 0xEE))

suite "rejections":
  test "invalid tags":
    check rejects @[byte 0x00]
    check rejects @[byte 0xB0]
    check rejects @[byte 0xF7]

  test "END misuse":
    check rejects @[byte 0xA0] # END at top level
    check rejects @[byte 0xA1]
    check rejects @[byte 0xA8] # END with mark bit
    check rejects @[byte 0xAF]

  test "nonzero length bits on null and frames":
    check rejects @[byte 0x11]
    check rejects @[byte 0x19] # marked null still needs zero length bits
    check rejects @[byte 0x61, 0xA0]
    check rejects @[byte 0x93, 0xA0]

  test "truncation":
    check rejects @[byte 0x23, 0x31] # int claims 3 bytes, has 1
    check rejects @[byte 0x37] # medium length byte missing
    check rejects @[byte 0x37, 0xFF, 0x00] # large length cut short
    check rejects @[byte 0x60] # unclosed list
    check rejects @[byte 0x60, 0x21, 0x31] # closed neither child nor list

  test "non-minimal lengths":
    check rejects @[byte 0x37, 0x03, 0x61, 0x61, 0x61]
    check rejects @[byte 0x37, 0xFF, 0x00, 0x00, 0x00, 0x10] & newSeqWith(16, byte 0x61)

  test "non-canonical integers":
    check rejects @[byte 0x20] # empty payload
    check rejects @[byte 0x22, 0x30, 0x37] # "07"
    check rejects @[byte 0x22, 0x2D, 0x30] # "-0"
    check rejects @[byte 0x21, 0x61] # "a"

  test "ill-formed UTF-8":
    check rejects @[byte 0x31, 0xFF] # lone invalid byte
    check rejects @[byte 0x32, 0xC3, 0x28] # bad continuation
    check rejects @[byte 0x32, 0xC0, 0xAF] # overlong solidus (2-byte)
    check rejects @[byte 0x33, 0xE0, 0x80, 0xAF] # overlong solidus (3-byte)
    check rejects @[byte 0x33, 0xED, 0xA0, 0x80] # surrogate U+D800
    check rejects @[byte 0x34, 0xF4, 0x90, 0x80, 0x80] # past U+10FFFF
    check rejects @[byte 0x42, 0xC3] # truncated sequence in sym

  test "record with no head":
    check rejects @[byte 0x70, 0xA0]

  test "sets and dicts must arrive sorted and unique":
    check rejects @[byte 0x90, 0x41, 0x62, 0x41, 0x61, 0xA0] # #{b a}
    check rejects @[byte 0x90, 0x41, 0x61, 0x41, 0x61, 0xA0] # #{a a}
    check rejects @[byte 0x80, 0x41, 0x62, 0x21, 0x31, 0x41, 0x61, 0x21, 0x32, 0xA0]
      # {b:1 a:2}
    check rejects @[byte 0x80, 0x41, 0x61, 0x21, 0x31, 0x41, 0x61, 0x21, 0x32, 0xA0]
      # {a:1 a:2}
    check rejects @[byte 0x80, 0x41, 0x61, 0xA0] # dangling key

  test "depth limit":
    check rejects newSeqWith(200, byte 0x60)

  test "trailing bytes":
    check rejects @[byte 0x10, 0x10]

suite "order is the encoding order":
  test "cmp(a, b) matches byte order of encodings":
    let vs = [
      nilValue(),
      num"0",
      num"9",
      num"10",
      num"-5",
      text"",
      text"a",
      text"b",
      text"aa",
      sym"a",
      mark(sym"a"),
      bytes(@[byte 0]),
      list(),
      list(sym"a"),
      list(sym"a", sym"b"),
      record(sym"h"),
      dict(@[(sym"k", num"1")]),
      set(num"1"),
    ]
    for a in vs:
      for b in vs:
        check sgn(cmp(a, b)) == sgn(cmp(encode(a), encode(b)))

suite "hashing":
  test "hash is CE identity":
    check hash(num"123") == hash(num"123")
    check hash(set(sym"a", sym"b")) == hash(set(sym"b", sym"a"))
    check hash(mark(sym"x")) != hash(sym"x") # mark is part of identity
    check hash(text"x") != hash(sym"x") # so is the tag

  test "hash agrees with ==":
    let vs = [
      nilValue(),
      num"0",
      num"9",
      text"",
      text"a",
      sym"a",
      mark(sym"a"),
      bytes(@[byte 0]),
      list(sym"a"),
      record(sym"h"),
      dict(@[(sym"k", num"1")]),
      set(num"1"),
    ]
    for a in vs:
      for b in vs:
        if a == b:
          check hash(a) == hash(b)

  test "works as Table and HashSet keys":
    var t = initTable[Value, string]()
    t[record(sym"point", num"1", num"2")] = "p"
    t[sym"point"] = "s"
    check t[record(sym"point", num"1", num"2")] == "p"
    check t.len == 2

    var s = initHashSet[Value]()
    s.incl num"1"
    s.incl num"1"
    s.incl dict(@[(sym"a", num"1"), (sym"b", num"2")])
    s.incl dict(@[(sym"b", num"2"), (sym"a", num"1")])
    check s.len == 2
    check num"1" in s
