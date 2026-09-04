## the text dialect: what the corpus does not already say. The
## reader's own cases (reads, refuses, incomplete, document) run in
## tcorpus; here the printer's layouts read back, prefixes of a text
## are never refused, and the rules around each token.

import std/[strutils, unittest]
import bl/core
import bl/lib/[blah, blmacro]
import ./corpus

template reads(s: string) =
  discard readValue(s)

template readsAs(s: string, v: Value) =
  check readValue(s) == v

template prints(v: Value, s: string) =
  check $v == s

template rejects(s: string) =
  expect ReadError:
    discard readValue(s)

template incomplete(s: string) =
  expect Incomplete:
    discard readDocument(s)

template refuses(s: string) =
  ## refused outright: an Incomplete is not a refusal
  expect ReadError:
    try:
      discard readDocument(s)
    except Incomplete:
      discard

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
    test name:
      for width in [high(int), 40, 16, 1]:
        readsAs pretty(value, width), value
      discard prefixesRead(pretty(value, 16))

  test "random values":
    # blah's values run to megabytes; a shallower value is enough here
    for _ in 0 ..< 200:
      let v = randValue(3)
      readsAs $v, v
      readsAs pretty(v, 40), v

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
    prints bl({b: 1, a: 2}), "{a: 2 b: 1}"
    prints bl({c, b, a}), "{a b c}"
    prints bl({10, 9, -1}), "{9 -1 10}"   # shortlex: '-' sorts before the digits

suite "nil":
  test "reserved, quotable, markable":
    readsAs "'nil'", sym"nil"
    readsAs "nil!", null(true)
    readsAs "nilx", sym"nilx"
    readsAs "nil", null()
    prints sym"nil", "'nil'"

suite "numbers":
  test "'_' separates digits and never survives the reading":
    readsAs "1_000_000", bl(1_000_000)
    prints readValue("1_000"), "1000"
    readsAs "_5", sym"_5"
    readsAs "_5_", sym"_5_"
  test "past int64 is held as spelled":
    check readValue("123456789012345678901234567890").num.isWide
    prints readValue("123456789012345678901234567890"), "123456789012345678901234567890"
    prints readValue("-123456789012345678901234567890"), "-123456789012345678901234567890"
    check readValue("9223372036854775807").num.isInt
    check readValue("9223372036854775808").num.isWide

suite "strings and symbols":
  test "escapes":
    readsAs "\"a\\n\\t\\r\\\\\\\"b\"", text("a\n\t\r\\\"b")
    readsAs "\"a\nb\"", text("a\nb")
    readsAs "'a\\'b'", sym"a'b"
    rejects "\"bad \\z escape\""
  test "bare symbols print bare":
    for s in ["->", "-", "<=", "+5", "*", "?", "a.b", ",", "a,b", "#", "#weird", "`tick"]:
      readsAs s, sym(s)
      prints sym(s), s
  test "a delimiter inside a symbol quotes it":
    readsAs "'a!b'", sym"a!b"
    prints sym"a!b", "'a!b'"
    prints sym"a b", "'a b'"
    prints sym"a:b", "'a:b'"
  test "malformed UTF-8 is refused":
    rejects "\"\xFF\""
    rejects "'\xC0\x80'"

suite "bytes":
  test "either case, '_' between digits":
    readsAs "0xDEAD", bl(x"dead")
    readsAs "0xde_ad", bl(x"dead")
    readsAs "0xd_e_a_d", bl(x"dead")
    readsAs "0x", bl(x"")
    prints bl(x"dead"), "0xdead"

suite "braces and marks":
  test "the first element decides set or dict":
    readsAs "{foo:bar}", bl({foo: bar})
    readsAs "{go!: 1}", bl({!go: 1})
  test "marks touch their value":
    readsAs "[go! stop]", bl([!go, stop])
    readsAs "(f go! !(g))", bl(f(!go, !g()))
    rejects "!;c\n(f)"

suite "documents":
  test "readValue wants exactly one value":
    reads "1"
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
