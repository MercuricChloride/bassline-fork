## the text dialect: reader and printer against the corpus, plus the
## reader's own rules
import pkg/core/reader
import ./corpus

proc rejects(t: string): bool =
  try:
    discard readValue(t)
    false
  except ReadError:
    true

# corpus: the text reads to the value, the value prints as the text,
# and what was read spells to the bytes
for c in cases():
  let v = readValue(c.text)
  doAssert v == c.value, c.name
  doAssert $v == c.text, c.name & ": printed " & $v
  doAssert $c.value == c.text, c.name
  doAssert spell(v) == c.bytes, c.name

# random values survive the text round trip
var g = initValueGen(23)
for _ in 0 ..< 1000:
  let v = g.genValue()
  let t = $v
  let back = readValue(t)
  doAssert back == v, t
  doAssert $back == t, t

# nil is reserved, quotable, markable
doAssert readValue("'nil'") == sym"nil"
doAssert readValue("nil!") == null(true)
doAssert readValue("nilx") == sym"nilx"

# numbers, and '_' as a digit separator that never survives the reading
doAssert readValue("1_000_000") == num 1_000_000
doAssert readValue("-1_000") == num(-1000)
doAssert $readValue("1_000") == "1000"
doAssert readValue("_5") == sym"_5"          # no digit in front: a symbol
doAssert readValue("_5_") == sym"_5_"
doAssert rejects("1_")
doAssert rejects("1__000")
doAssert rejects("0_0")                       # canonicality is judged on the digits
for s in ["007", "-0", "1.5", "42px", "1-2", "1."]:
  doAssert rejects(s), s
doAssert readValue("123456789012345678901234567890").num.isWide  # past int64 is held as spelled
doAssert $readValue("-123456789012345678901234567890") == "-123456789012345678901234567890"

# strings
doAssert readValue("\"a\\n\\t\\r\\\\\\\"b\"") == text("a\n\t\r\\\"b")
doAssert readValue("\"a\nb\"") == text("a\nb")          # a literal newline is legal

# symbols
for s in ["->", "-", "<=", "+5", "*", "?", "a.b", ",", "a,b", "#", "#weird", "`tick"]:
  doAssert readValue(s) == sym(s), s
  doAssert $sym(s) == s, s
doAssert readValue("'a\\'b'") == sym"a'b"
doAssert readValue("'a!b'") == sym"a!b"                  # '!' delimits, so quoted
doAssert $sym"a!b" == "'a!b'"

# bytes
doAssert readValue("0xDEAD") == bytes(@[byte 0xDE, 0xAD])   # either case reads
doAssert readValue("0xde_ad") == bytes(@[byte 0xDE, 0xAD])
doAssert readValue("0xd_e_a_d") == bytes(@[byte 0xDE, 0xAD])
doAssert rejects("0x123")
doAssert rejects("0x_de")

# braces: the first element decides set or dict
doAssert readValue("{foo:bar}") == initDict(@[(sym"foo", sym"bar")])
doAssert readValue("{go!: 1}") == initDict(@[(sym("go", true), num 1)])
doAssert rejects("{a b: c}")
doAssert rejects("{a: 1 b}")
doAssert rejects("{: a}")
doAssert rejects("{a:}")
doAssert rejects("{1 1}")                     # duplicate member
doAssert rejects("{a: 1 a: 2}")               # duplicate key
doAssert rejects("()")                        # a record needs a head

# marks: atoms behind, frames in front, touching
doAssert readValue("[go! stop]") == initList(@[sym("go", true), sym"stop"])
doAssert readValue("(f go! !(g))") ==
  initRec(@[sym"f", sym("go", true), initRec(@[sym"g"], true)])
for s in ["! (f)", "!!(f)", "!", "!x", "(f)!", "!(f)!", "go !", "a!b", "!;c\n(f)"]:
  doAssert rejects(s), s

# documents and comments
doAssert readDocument("1 2 3").len == 3
doAssert readDocument("; only a comment\n").len == 0
doAssert $readValue("; a comment\n5") == "5"
doAssert rejects("1 2")                       # readValue wants exactly one
doAssert rejects("")
doAssert rejects("[1")
doAssert rejects("\"\xFF\"")                  # malformed UTF-8
doAssert rejects("'\xC0\x80'")

# Incomplete: a prefix of a valid text that ends at whitespace -- so
# every token in it is terminated -- is never refused outright: it
# reads, or it is Incomplete (a ReadError, so old handlers still catch
# it). Refusals proper are decided by the text already present
block:
  var incompletes = 0
  for c in cases():
    let t = c.text
    for n in 1 .. t.len:
      if t[n - 1] notin {' ', '\n', '\t'}: continue
      try:
        discard readDocument(t[0 ..< n])
      except Incomplete:
        inc incompletes
      except ReadError as e:
        doAssert false, c.name & " prefix " & $n & " refused: " & e.msg
  doAssert incompletes > 0
  for t in ["[1 2", "(f a", "{a: 1", "{a b", "{a", "{a:", "\"open", "!", "[1 [2] "]:
    try:
      discard readDocument(t)
      doAssert false, "read as complete: " & t
    except Incomplete:
      discard
  for t in ["{a: 1 b}", "[1)", "\"bad \\z escape\"", "{a: 1 a: 2}", "()"]:
    try:
      discard readDocument(t)
      doAssert false, "accepted: " & t
    except Incomplete:
      doAssert false, "incomplete, should be refused: " & t
    except ReadError:
      discard

echo "reader ok"
