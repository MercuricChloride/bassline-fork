## The library's laws: numbers and comparing answer values (nil is the
## only false), the mezzanine written in boot.bl behaves as its docs say,
## introspection answers values, and man renders every doc.

import std/[strutils, unittest]
import library

useValue Val

proc fresh(): Val =
  ## a workspace below a newly booted library
  workspace(bootLibrary())

template ev(scope: Val, text: string): Val =
  scope.run(text)

proc parsed(text: string): Val = Val.parse(text)

suite "numbers":
  test "add, sub, mul, div and mod":
    let ws = fresh()
    check ws.ev("(add)") == parsed("0")
    check ws.ev("(add 1 2 3)") == parsed("6")
    check ws.ev("(sub 5)") == parsed("-5")
    check ws.ev("(sub 10 3 2)") == parsed("5")
    check ws.ev("(mul 2 3 4)") == parsed("24")
    check ws.ev("(div 7 2)") == parsed("3")
    check ws.ev("(div -7 2)") == parsed("-3")
    check ws.ev("(mod -7 2)") == parsed("-1")
    check ws.ev("(mul 9223372036854775807 2)") == parsed("18446744073709551614")

  test "refusals":
    let ws = fresh()
    expect BasslineError:
      discard ws.ev "(div 1 0)"
    expect BasslineError:
      discard ws.ev "(mod 1 0)"
    expect BasslineError:
      discard ws.ev "(add 1 \"two\")"

suite "comparing":
  test "a comparison that holds answers its first argument":
    let ws = fresh()
    check ws.ev("(eq 3 3)") == parsed("3")
    check ws.ev("(eq 3 4)") == parsed("nil")
    check ws.ev("(ne 3 4)") == parsed("3")
    check ws.ev("(lt 2 10)") == parsed("2")
    check ws.ev("(lt 10 2)") == parsed("nil")
    check ws.ev("(le 2 2)") == parsed("2")
    check ws.ev("(gt -1 -5)") == parsed("-1")
    check ws.ev("(ge 1 2)") == parsed("nil")
    check ws.ev("(lt \"a\" \"b\")") == parsed("\"a\"")

  test "nil is the only false":
    let ws = fresh()
    check ws.ev("(eq nil nil)") == parsed("true")
    check ws.ev("(not nil)") == parsed("true")
    check ws.ev("(not 0)") == parsed("nil")
    check ws.ev("(if (eq 0 0) 1 2)") == parsed("1")

suite "values":
  test "building and taking apart":
    let ws = fresh()
    check ws.ev("(list 1 (add 1 1))") == parsed("[1 2]")
    check ws.ev("(record (quote p) 1 2)") == parsed("(p 1 2)")
    check ws.ev("(to-record [p 1])") == parsed("(p 1)")
    check ws.ev("(first [a b])") == parsed("a")
    check ws.ev("(first [])") == parsed("nil")
    check ws.ev("(rest [a b c])") == parsed("[b c]")
    check ws.ev("(rest (quote (h x y)))") == parsed("[x y]")
    check ws.ev("(append [1] 2 3)") == parsed("[1 2 3]")
    check ws.ev("(append {1} 3 2)") == parsed("{1 2 3}")
    check ws.ev("(concat [1] [2 3])") == parsed("[1 2 3]")
    check ws.ev("(concat \"ab\" (quote cd))") == parsed("\"abcd\"")
    check ws.ev("(keys {b: 2 a: 1})") == parsed("[a b]")
    check ws.ev("(vals {b: 2 a: 1})") == parsed("[1 2]")

  test "len, has, kind, text and join":
    let ws = fresh()
    check ws.ev("(len [1 2 3])") == parsed("3")
    check ws.ev("(len {a: 1 b: 2})") == parsed("2")
    check ws.ev("(len \"日本\")") == parsed("2")
    check ws.ev("(has {a: 1} (quote a))") == parsed("a")
    check ws.ev("(has [1 2] 3)") == parsed("nil")
    check ws.ev("(has \"hello\" \"ell\")") == parsed("\"ell\"")
    check ws.ev("(kind 1)") == parsed("number")
    check ws.ev("(kind (quote (a)))") == parsed("record")
    check ws.ev("(kind (make nil {}))") == parsed("object")
    check ws.ev("(text (quote sym))") == parsed("\"sym\"")
    check ws.ev("(text [1 \"a\"])") == parsed("\"[1 \\\"a\\\"]\"")
    check ws.ev("(join [a 1 \"b\"] \", \")") == parsed("\"a, 1, b\"")

  test "print answers nil":
    let ws = fresh()
    check ws.ev("(print \"printed by tlibrary\" 1)") == parsed("nil")

suite "control":
  test "while loops without recursion":
    let ws = fresh()
    discard ws.ev "(def i 0) (def sum 0)"
    discard ws.ev "(while (lt i 1000) (set sum (add sum i)) (set i (add i 1)))"
    check ws.ev("sum") == parsed("499500")

suite "mezzanine":
  test "when, unless, and, or, cond":
    let ws = fresh()
    check ws.ev("(when 1 2 3)") == parsed("3")
    check ws.ev("(when nil 2 3)") == parsed("nil")
    check ws.ev("(unless nil 2)") == parsed("2")
    check ws.ev("(unless 1 2)") == parsed("nil")
    check ws.ev("(and 1 2 3)") == parsed("3")
    check ws.ev("(and 1 nil 3)") == parsed("nil")
    check ws.ev("(and)") == parsed("true")
    check ws.ev("(or nil nil 4)") == parsed("4")
    check ws.ev("(or nil)") == parsed("nil")
    discard ws.ev "(def x 5)"
    check ws.ev("(cond [(lt x 0) (quote neg)] [(eq x 0) (quote zero)] [else (quote pos)])") ==
      parsed("pos")
    check ws.ev("(cond [nil 1])") == parsed("nil")

  test "and and or stop early":
    let ws = fresh()
    discard ws.ev "(def hits 0)"
    discard ws.ev "(and nil (set hits 1))"
    discard ws.ev "(or 1 (set hits 2))"
    check ws.ev("hits") == parsed("0")

  test "each, map, filter and apply":
    let ws = fresh()
    discard ws.ev "(def total 0)"
    discard ws.ev "(each [1 2 3] (fn [n] (set total (add total n))))"
    check ws.ev("total") == parsed("6")
    check ws.ev("(map [1 2 3] (fn [n] (mul n n)))") == parsed("[1 4 9]")
    check ws.ev("(filter [1 2 3 4] (fn [n] (eq (mod n 2) 0)))") == parsed("[2 4]")
    check ws.ev("(apply add [1 2 3])") == parsed("6")
    check ws.ev("(apply list (list (quote a) [b]))") == parsed("[a [b]]")
    check ws.ev("(apply list [(quote a)])") == parsed("[(quote a)]")

  test "a block passed in sees the call it was made in":
    let ws = fresh()
    discard ws.ev "(defn scaled [items k] (map items (fn [n] (mul n k))))"
    check ws.ev("(scaled [1 2] 10)") == parsed("[10 20]")

  test "inc and dec take any reference":
    let ws = fresh()
    discard ws.ev "(def n 1)"
    discard ws.ev "(inc n)"
    check ws.ev("n") == parsed("2")
    discard ws.ev "(dec n 5)"
    check ws.ev("n") == parsed("-3")
    discard ws.ev "(def xs [1 2 3])"
    discard ws.ev "(inc (at xs 2) 10)"
    check ws.ev("xs") == parsed("[1 2 13]")
    discard ws.ev "(def c (make nil {count: 0}))"
    discard ws.ev "(inc [c count])"
    check ws.ev("(get [c count])") == parsed("1")

  test "defn and let":
    let ws = fresh()
    discard ws.ev "(defn twice \"(twice N)\nN added to itself.\" [n] (add n n))"
    check ws.ev("(twice 21)") == parsed("42")
    check ws.ev("(layer twice doc)") == parsed("(doc \"(twice N)\\nN added to itself.\")")
    discard ws.ev "(defn plain [] 1)"
    check ws.ev("(plain)") == parsed("1")
    check ws.ev("(let {a: 1 b: (add 1 1)} (add a b))") == parsed("3")

  test "library functions see the root, not their caller":
    let ws = fresh()
    discard ws.ev "(def rest (fn [x] (quote shadowed)))"
    check ws.ev("(when 1 2)") == parsed("2")
    check ws.ev("(map [1] (fn [n] n))") == parsed("[1]")

suite "introspection":
  test "describe, slots and parent-of":
    let ws = fresh()
    discard ws.ev "(def p (make nil {a: 1}))"
    discard ws.ev "(def o (make p {b: 2}))"
    discard ws.ev "(document o \"an o\")"
    let d = ws.ev("(describe o)")
    check d.dict.getOr(parsed("slots"), nil) == parsed("[b >>parent]")
    check d.dict.getOr(parsed("layers"), nil) == parsed("{(doc \"an o\")}")
    check d.dict.getOr(parsed("id"), nil).kind == bBytes
    check ws.ev("(slots p)") == parsed("[a]")
    check ws.ev("(parent-of o)") == ws.ev("p")
    check ws.ev("(parent-of p)") == parsed("nil")

  test "trace answers its form's value":
    let ws = fresh()
    check ws.ev("(trace (add 1 2))") == parsed("3")
    check not image.tracing

suite "man":
  test "a native's page shows its usage and summary":
    let ws = fresh()
    let page = manFor(parsed("add"), ws)
    check page.startsWith("add\n")
    check "(add N …)" in page
    check "The sum of the numbers" in page
    check "carries: native" in page

  test "a mezzanine page shows see also":
    let ws = fresh()
    let page = manFor(parsed("when"), ws)
    check "(when TEST FORM …)" in page
    check "see also: unless if cond" in page

  test "topics are found by name":
    let ws = fresh()
    check "send and references" in manFor(parsed("send"), ws)
    check "generalized reference" in manFor(parsed("places"), ws)
    let both = manFor(parsed("image"), ws)
    check "the image and its history" in both

  test "an object without a doc is described":
    let ws = fresh()
    discard ws.ev "(def o (make nil {a: 1}))"
    let page = manFor(parsed("o"), ws)
    check "no doc" in page
    check "slots: a" in page
    check "id: 0x" in page

  test "docs are live":
    let ws = fresh()
    discard ws.ev "(def o (make nil {}))"
    discard ws.ev "(set (layer o doc) (quote (doc \"(o)\nAn object of mine.\")))"
    check "An object of mine." in manFor(parsed("o"), ws)
    discard ws.ev "(document o {usage: \"(o)\" summary: \"Mine still.\" see: [make]})"
    let page = manFor(parsed("o"), ws)
    check "Mine still." in page
    check "see also: make" in page

  test "references and data":
    let ws = fresh()
    discard ws.ev "(def c (make nil {count: 0}))"
    check "count holds 0" notin manFor(parsed("[c count]"), ws)
    check "holds 0, a number" in manFor(parsed("[c count]"), ws)
    expect BasslineError:
      discard manFor(parsed("no-such-thing"), ws)

  test "the index lists names and topics":
    discard fresh()
    let index = manIndex()
    check "  when" in index
    var topics = ""
    for line in index.splitLines:
      if line.startsWith("topics in the manual:"):
        topics = line
    for topic in ["objects", "send", "places", "prototypes", "image", "documenting"]:
      check topic in topics

  test "apropos searches names and docs":
    discard fresh()
    let found = aproposText("REFERENCE")
    check "topic places" in found
    check "inc" in found
    check aproposText("zzz-nothing").len == 0

  test "every root name has a doc":
    discard fresh()
    let root = image.root
    var missing: seq[string]
    for name in root.slotNames:
      let v = root.ownSlot(name)
      if not v.isObject or v.docOf.isNil:
        missing.add name.textOf
    check missing.len == 0
    if missing.len > 0:
      echo "undocumented: ", missing
