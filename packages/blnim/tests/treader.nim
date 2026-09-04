## the text dialect: what the corpus does not already say. The
## reader's own cases (reads, refuses, incomplete, document) run in
## tcorpus. Here a text is checked by the CE bytes it reads to, and
## a printing by the bytes it starts from, so the oracle is the spec's
## encoding and never another front end.

import std/[strutils, unittest]
import bl/core
import bl/lib/blah
import ./corpus

proc ce(hex: string): seq[byte] =
  ## CE bytes spelled in hex, spaces between for the eye
  @(hex.replace(" ", "").parseHexStr.toBytes)

template spells(s: string, hex: string) =
  ## the text reads to the value whose canonical encoding is hex
  check ceBytes(readValue(s)) == ce(hex)

template prints(hex: string, s: string) =
  ## the value whose canonical encoding is hex prints as s
  let l = land(ce(hex))
  require l.values.len == 1
  check $l.values[0].toValue == s

proc prefixesRead(t: string): int =
  ## every prefix ending in whitespace has all its tokens terminated,
  ## so it reads or is Incomplete, never refused; counts the incompletes
  for n in 1 .. t.len:
    if t[n - 1] notin {' ', '\n', '\t'}: continue
    try:
      discard readDocument(t[0 ..< n])
    except Incomplete:
      inc result
    except ReadError as e:
      checkpoint(t & " prefix " & $n & " refused: " & e.msg)
      check false

suite "printer":
  filter ce, c:
    let
      name = c.items[1].text
      value = c.items[2]
      expect = c.items[3].bytes
    test name:
      for width in [high(int), 40, 16, 1]:
        check ceBytes(readValue(pretty(value, width))) == expect
      discard prefixesRead(pretty(value, 16))

  test "random values":
    # blah's values run to megabytes; a shallower value is enough here
    for _ in 0 ..< 200:
      let v = randValue(3)
      check readValue($v) == v
      check readValue(pretty(v, 40)) == v

  test "prefixes of small random values":
    # the prefix law reads every prefix, so keep the texts short
    var incompletes = 0
    var n = 0
    while n < 50:
      let t = pretty(randValue(4), 40)
      if t.len > 400: continue
      incompletes += prefixesRead(t)
      inc n
    check incompletes > 0

  test "dicts and sets print in canonical order":
    prints "80 4161 2132 4162 2131 a0", "{a: 2 b: 1}"
    prints "90 4161 4162 4163 a0", "{a b c}"
    prints "90 2139 222d31 223130 a0", "{9 -1 10}"   # shortlex: '-' sorts before the digits

suite "nil":
  test "reserved, quotable, markable":
    spells "nil", "10"
    spells "nil!", "18"
    spells "'nil'", "43 6e696c"
    spells "nilx", "44 6e696c78"
    prints "43 6e696c", "'nil'"

suite "numbers":
  test "'_' separates digits and never survives the reading":
    spells "1_000_000", "27 07 31303030303030"
    spells "_5", "42 5f35"
    spells "_5_", "43 5f355f"
  test "past int64 reads and prints as spelled":
    spells "123456789012345678901234567890",
      "27 1e 313233343536373839303132333435363738393031323334353637383930"
    prints "27 1f 2d313233343536373839303132333435363738393031323334353637383930",
      "-123456789012345678901234567890"

suite "strings and symbols":
  test "escapes":
    spells "\"a\\n\\t\\r\\\\\\\"b\"", "37 07 61 0a 09 0d 5c 22 62"
    spells "\"a\nb\"", "33 61 0a 62"
    spells "'a\\'b'", "43 61 27 62"
    rejects "\"bad \\z escape\""
  test "bare symbols read bare and print bare":
    for (s, hex) in [("->", "42 2d3e"), ("-", "41 2d"), ("<=", "42 3c3d"),
                     ("+5", "42 2b35"), ("*", "41 2a"), ("?", "41 3f"),
                     ("a.b", "43 612e62"), (",", "41 2c"), ("a,b", "43 612c62"),
                     ("#", "41 23"), ("#weird", "46 237765697264"),
                     ("`tick", "45 607469636b")]:
      checkpoint(s)
      spells s, hex
      prints hex, s
  test "a delimiter inside a symbol quotes it":
    spells "'a!b'", "43 612162"
    prints "43 612162", "'a!b'"
    prints "43 612062", "'a b'"
    prints "43 613a62", "'a:b'"
  test "malformed UTF-8 is refused":
    rejects "\"\xFF\""
    rejects "'\xC0\x80'"

suite "bytes":
  test "either case, '_' between digits":
    spells "0xDEAD", "52 dead"
    spells "0xde_ad", "52 dead"
    spells "0xd_e_a_d", "52 dead"
    spells "0x", "50"
    prints "52 dead", "0xdead"

suite "braces and marks":
  test "the first element decides set or dict":
    spells "{foo:bar}", "80 43666f6f 43626172 a0"
    spells "{go!: 1}", "80 4a676f 2131 a0"
  test "marks touch their value":
    spells "[go! stop]", "60 4a676f 4473746f70 a0"
    spells "(f go! !(g))", "70 4166 4a676f 78 4167 a0 a0"
    rejects "!;c\n(f)"

suite "documents":
  test "readValue wants exactly one value":
    spells "1", "21 31"
    rejects ""
    rejects "1 2"
  test "Incomplete is a ReadError, so a prefix is rejected too":
    rejects "[1"
    rejects "\"open"
    incomplete "[1"
    incomplete "\"open"
  test "refused outright, not incomplete":
    refuses "{a: 1 b}"
    refuses "[1)"
    refuses "\"bad \\z escape\""
    refuses "{a: 1 a: 2}"
    refuses "()"
