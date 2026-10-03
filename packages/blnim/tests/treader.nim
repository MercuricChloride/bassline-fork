## the text dialect: what the corpus does not already say. The
## reader's own cases (reads, refuses, incomplete, document) run in
## tcorpus. Here a text is checked by the CE bytes it reads to, and
## a printing by the bytes it starts from, so the oracle is the spec's
## encoding and never another front end.

import std/[importutils, random, strutils, unittest]
from std/sequtils import repeat
import bl/core
import bl/lib/blah
import ./corpus

proc ce(hex: string): seq[byte] =
  ## CE bytes spelled in hex, spaces between for the eye
  @(hex.replace(" ", "").parseHexStr.toBytes)

template spells(s: string, hex: string) =
  ## the text reads to the value whose canonical encoding is hex
  check readValue(s).ce == ce(hex)

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
  filter "ce", c:
    let
      name = c.items[1].text
      value = c.items[2]
      expect = c.items[3].bytes
    test name:
      for width in [high(int), 40, 16, 1]:
        check readValue(pretty(value, width)).ce == expect
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
    spells " 1 ; and nothing more", "21 31"
    rejects ""
    rejects "1 2"
  test "a second value begun is refused however it ends":
    refuses " ; only a comment\n"
    refuses "1 ["
    refuses "[1] \"open"
    refuses "go !"
    incomplete "!"
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

# a Reader fed in pieces reads as the whole text does: the same values,
# each as soon as no piece to come can change it, then the same
# refusal at the same line and column

type Fed = object
  values: seq[Value]
  error: string   # what stopped the reading, and where

proc fed(t: string, cuts: openArray[int]): Fed =
  ## t fed a piece at a time, each piece ending at the next cut and
  ## the last at the end of t, then finished
  var r: Reader
  var lo = 0
  try:
    for hi in @cuts & t.len:
      r.add t[lo ..< hi]
      lo = hi
      for v in r:
        result.values.add v
    for v in r.finish:
      result.values.add v
  except Incomplete as e:
    result.error = "incomplete: " & e.msg
  except ReadError as e:
    result.error = "refused: " & e.msg

proc whole(t: string): Fed =
  ## t read whole, as readDocument reads it
  try:
    readDocument(t, result.values)
  except Incomplete as e:
    result.error = "incomplete: " & e.msg
  except ReadError as e:
    result.error = "refused: " & e.msg

proc randomCuts(len: int): seq[int] =
  for cut in 1 ..< len:
    if rand(4) == 0: result.add cut

template readsAlike(t: string) =
  ## fed in one piece, a character at a time, or split at random
  ## points, t reads as it does whole
  let w = whole(t)
  check fed(t, []) == w
  check fed(t, every(1, t.len)) == w
  for _ in 0 ..< 8:
    check fed(t, randomCuts(t.len)) == w

proc stops(pieces: openArray[string]): tuple[piece: int, error: string] =
  ## the piece after which a reader, read after every piece, refuses,
  ## and why: pieces.len if only finish refuses, -1 if nothing does
  var r: Reader
  try:
    for i, p in pieces:
      result.piece = i
      r.add p
      for v in r: discard
    result.piece = pieces.len
    for v in r.finish: discard
    result.piece = -1
  except Incomplete as e:
    result.error = "incomplete: " & e.msg
  except ReadError as e:
    result.error = "refused: " & e.msg

proc after(pieces: openArray[string]): seq[seq[Value]] =
  ## what a reader hands back after each piece, and then at finish
  var r: Reader
  for p in pieces:
    r.add p
    result.add @[]
    for v in r:
      result[^1].add v
  result.add @[]
  for v in r.finish:
    result[^1].add v

suite "fed in pieces":
  filter "reads", c:
    let src = c.items[1].text
    test "reads " & src.escape:
      readsAlike src
      check fed(src, every(1, src.len)).values == @[c.items[2]]

  filter "refuses", c:
    let src = c.items[1].text
    test "refuses " & src.escape:
      readsAlike src
      let f = fed(src, every(1, src.len))
      check f.error.startsWith("refused") or
            (f.error == "" and f.values.len != 1) or   # readValue's one value
            (f.values.len > 0 and f.error.startsWith("incomplete"))
              # or a second value begun

  filter "incomplete", c:
    let src = c.items[1].text
    test "incomplete " & src.escape:
      readsAlike src
      check fed(src, every(1, src.len)).error.startsWith("incomplete")

  filter "document", c:
    let src = c.items[1].text
    test "document " & src.escape:
      readsAlike src
      check fed(src, every(1, src.len)).values == c.items[2].items.data

  test "a value comes out once no piece to come can change it":
    let
      a = initRec(@[sym"a"])
      b = initRec(@[sym"b"])
    check after(["(a) (b", ")"]) == @[@[a], @[], @[b]]
    check after(["(a)", "(b)"]) == @[@[], @[a], @[b]]   # (a)! is refused
    check after(["1 2 3"]) == @[@[num(1), num(2)], @[num(3)]]
    check after(["12", "3 "]) == @[@[], @[num(123)], @[]]
    check after(["ab", "c "]) == @[@[], @[sym"abc"], @[]]
    check after(["ni", "l "]) == @[@[], @[null()], @[]]
    check after(["ni", "lx "]) == @[@[], @[sym"nilx"], @[]]
    check after(["0xde", "ad "]) == @[@[], @[bytes(@[0xde'u8, 0xad])], @[]]
    check after(["go", "!", " "]) == @[@[], @[], @[sym("go", true)], @[]]
    check after(["!", "(f) "]) == @[@[], @[initRec(@[sym"f"], true)], @[]]
    check after(["\"ab", "c\" "]) == @[@[], @[text"abc"], @[]]
    check after(["\"a\\", "n\" "]) == @[@[], @[text("a\n")], @[]]
    check after(["; com", "ment\n5 "]) == @[@[], @[num(5)], @[]]
    check after(["[1 [2", "] 3", "] "]) ==
      @[@[], @[], @[initList(@[num(1), initList(@[num(2)]), num(3)])], @[]]

  test "a long string or frame is read again once it closes":
    # the long first piece is waited on and puts the next read off, so
    # only what `scan` sees in the second piece can bring it forward
    let long = 'a'.repeat(100)
    check after(["\"" & long, "\"x"]) ==
      @[@[], @[text long], @[sym"x"]]                     # a string closing
    check after(["[" & long, "]x"]) ==
      @[@[], @[initList(@[sym long])], @[sym"x"]]         # a frame closing
    check after(["[\"" & long, "\\\"\" 1] 2 "]) ==   # past an escaped quote
      @[@[], @[initList(@[text(long & "\""), num(1)]), num(2)], @[]]

  test "what comes next can still refuse what came before":
    check fed("(a)!", [3]).error ==
      "refused: line 1, col 4: a frame is marked in front: !(…)"
    check fed("go!x", [3]).error ==
      "refused: line 1, col 4: a marked atom ends at a delimiter"
    check fed("12px", [2]).error ==
      "refused: line 1, col 1: not a canonical number: 12px"

  test "errors say where they are in all the text fed":
    let t = "(a)\n[b c]\n  {d: e\n  ) "
    readsAlike t
    check whole(t).error == "refused: line 4, col 3: unexpected )"
    check fed(t, [4, 10, 13, 19]).error == whole(t).error
    let open = "(a)\n[b c]\n  {d: e"
    readsAlike open
    check fed(open, [4, 10]).error == "incomplete: line 3, col 8: unclosed {"

  test "random printings, whole and spoiled":
    const spoilers = "()[]{}:!;'\" \n_0x-a1\\"
    var n = 0
    while n < 60:
      let v = randValue(4)
      let t = pretty(v, 40)
      if t.len > 300: continue
      inc n
      readsAlike t
      check fed(t, randomCuts(t.len)).values == @[v]
      var spoiled = t
      spoiled[rand(t.high)] = spoilers[rand(spoilers.high)]
      readsAlike spoiled

  test "a long document in small pieces":
    var
      values: seq[Value]
      t: string
    for _ in 0 ..< 300:
      let v = randValue(4)
      values.add v
      t.add pretty(v, 60)
      t.add "\n"
    check fed(t, every(7, t.len)).values == values
    check fed(t, randomCuts(t.len)).values == values

  test "whitespace and comments between values are read as they come":
    privateAccess(Reader)
    var
      r: Reader
      got: seq[Value]
      held = 0
    r.add "(a)"
    for _ in 0 ..< 5000:
      r.add " "
      for v in r: got.add v
      held = max(held, r.text.len)
    for _ in 0 ..< 5000:
      r.add "; keep going\n"
      for v in r: got.add v
      held = max(held, r.text.len)
    check got == @[initRec(@[sym"a"])]
    check held <= "; keep going\n".len + 1
    check after(["  ; com", "ment\n5 "]) == @[@[], @[num(5)], @[]]

  test "a closer out of place is refused when it arrives":
    let fill = sequtils.repeat("(x) ", 1000)
    check stops(@["[ (", " ] "] & fill) == (1, whole("[ ( ] ").error)
    check stops(@["{a: 1 (", "} "] & fill) == (1, whole("{a: 1 (} ").error)

  test "a refusal in a frame still open comes out once the text doubles":
    let fill = sequtils.repeat(" 1 ", 1000)
    for (a, b) in [("[12", "px "), ("[(", ")"), ("[{a", " a}"),
                   ("[\"a\\", "z\"")]:
      checkpoint(a & b)
      let r = stops(@[a, b] & fill)
      check r.error == whole(a & b & fill.join("")).error
      check r.piece in 1 .. 3

  test "a mark at the top lets the next character decide":
    check stops(["go!", "x", "yz"]) ==
      (1, "refused: line 1, col 4: a marked atom ends at a delimiter")
    check stops(["!", "x", "yz"]) ==
      (1, "refused: line 1, col 2: only a frame is marked in front; " &
          "an atom is marked behind: x!")

  test "a loop left early leaves the rest for the next":
    var
      r: Reader
      first, rest: seq[Value]
    r.add "1 2 3 "
    for v in r:
      first.add v
      break
    for v in r:
      rest.add v
    check first == @[num(1)]
    check rest == @[num(2), num(3)]

  test "no text is fed after finish":
    var r: Reader
    r.add "1"
    for v in r.finish: discard
    expect AssertionDefect:
      r.add " 2"
