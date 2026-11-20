## lang: doing marked values, the kernel's convention, natives, rules,
## functions as values, and the base vocabulary

import std/[unittest, options, strutils]
import bl/lang

refuseWith BasslineError

proc v(text: string): Value = readValue(text)
proc vs(texts: varargs[string]): seq[Value] =
  for t in texts: result.add v(t)

var heard: seq[Value]
proc cx(): Cx =
  heard = @[]
  base((x: Value) => heard.add x)

proc answers(c: Cx, text: string): seq[Value] = toSeq(c.eval(v(text)))
proc answers(text: string): seq[Value] = cx().answers(text)

template answersAre(text: string, expected: varargs[string]) =
  check answers(text) == vs(expected)

template refuses(call: untyped) =
  expect BasslineError:
    discard call

# a tally of what was told, and a cx whose !(put Q A) tells it
type Told = ref object
  values: seq[Value]

proc tally(t: Told, takes = true): Send[Value, Value] =
  newSend[Value, Value]((q, a) => (block:
    t.values.add initRec(@[q, a])
    takes))

# doers for the tests: every natural, and two halvings
type Nat = ref object of Doer

method fits(d: Nat, x: Value): bool = x.isKind(bRec) and x.items.len == 1
method answers(d: Nat, x: Value, c: Cx): Stream[Value] =
  var n = 0
  () -> Option[Value] => (block:
    result = some(num(n))
    inc n)

# an object's doer: what a greeting says
type Greet = ref object of Doer

method answers(d: Greet, x: Value, c: Cx): Stream[Value] =
  x.answers(sym"said")

moldable """{
  !(struct half {exact (rep record)} (n number))
  !(struct takes {exact (rep record)} (data bytes!))
  !(struct span {(rep record)} (a number) (b {optional} number))
  !(struct point {exact (rep dict)} (x number) (y number))
}"""

method run(c: Half, x: Cx): Stream[Value] =
  let n = c.n.toInt
  guard n mod 2 == 0, "half of an odd number isn't a number"
  just num(n div 2)

method run(c: Takes, x: Cx): Stream[Value] = just bytes(c.data, mark = true)

method run(c: Point, x: Cx): Stream[Value] =
  just initList(@[c.x.toValue, c.y.toValue])

method run(c: Span, x: Cx): Stream[Value] =
  just initList(@[c.a.toValue, (if c.b.isSome: c.b.get.toValue else: null())])

suite "the convention":
  test "an unmarked value answers itself, whole, nothing inside it done":
    let t = Told()
    let c = cx()
    c.install(t.tally)
    check c.answers("[1 !(add 1 2) (go !(put x 1))]") == vs("[1 !(add 1 2) (go !(put x 1))]")
    check t.values.len == 0

  test "a call's direct marked arguments are done before it":
    answersAre "!(add !(mul 2 3) 4)", "10"

  test "a marked list, dict or set is made with its direct marked parts done":
    answersAre "![1 !(add 1 2) [!(add 1 2)]]", "[1 3 [!(add 1 2)]]"
    answersAre "!{a: !(add 1 2) b: 4}", "{a: 3 b: 4}"
    answersAre "!{!(add 1 2) 4}", "{3 4}"

  test "a later argument is done once for each answer before it, and not at all for none":
    let t = Told()
    let c = cx()
    c.install(t.tally)
    check c.answers("!(then !(lt 5 3) !(put said never))").len == 0
    check t.values.len == 0
    check c.answers("!(then !(lt 1 3) !(put said small))") == vs("taken")
    check c.answers("!(then !(in [a b]) !(put said each))") == vs("taken", "taken")
    check t.values == vs("(said small)", "(said each)", "(said each)")

  test "answers are crossed fairly, so an endless argument holds nothing up":
    let c = cx()
    c.install(sym"nat", Nat())
    check v"[b 0]" in toSeq(c.eval(v"![!(in [a b]) !(nat)]").take(4))

  test "a call nothing in reach can do answers nothing, and is heard":
    let c = cx()
    check c.answers("!(nope 1)").len == 0
    check heard == vs("!(nope 1)")

  test "an unknown guard does nothing that follows it":
    let t = Told()
    let c = cx()
    c.install(t.tally)
    check c.answers("!(then !(sensor-ok) !(put audit ran))").len == 0
    check c.answers("!(else [!(sensor-ok)] [fallback])") == vs("fallback")
    check t.values.len == 0

suite "finding doers":
  test "the nearest doer that answers gives every answer it has":
    let outer = cx()
    outer.install(native Half)
    let inner = outer.within
    inner.install(rules(vs("(rule (shape !(half n) {n}) [!(record ratio n! 2)])")))
    check inner.answers("!(half 8)") == vs("(ratio 8 2)")

  test "one that refuses or answers nothing passes the call on":
    let outer = cx()
    outer.install(rules(vs("(rule (shape !(half n) {n}) [!(record ratio n! 2)])")))
    let inner = outer.within
    inner.install(native Half)
    check inner.answers("![!(half 8) !(half 7)]") == vs("[4 (ratio 7 2)]")

  test "a refusal is about one call: the other branches go on":
    answersAre "!(all [!(div 12 !(in [1 0 2]))])", "[12 6]"

  test "a refusal is raised when nothing else answers":
    let c = cx()
    c.install(native Half)
    refuses c.answers("!(half 7)")

  test "a struct that doesn't read the call doesn't fit it":
    let c = cx()
    c.install(native Half)
    check c.answers("!(half x)").len == 0
    check heard == vs("!(half x)")

  test "readings are every doer's answers":
    let outer = cx()
    outer.install(rules(vs("(rule (shape !(half n) {n}) [!(record ratio n! 2)])")))
    let inner = outer.within
    inner.install(native Half)
    check inner.answers("!(readings [!(half 8)])") == vs("4", "(ratio 8 2)")

  test "something done answers that it was, so it isn't done again further out":
    let (near, far) = (Told(), Told())
    let outer = cx()
    outer.install(far.tally)
    let inner = outer.within
    inner.install(near.tally)
    check inner.answers("!(put x 1)") == vs("taken")
    check near.values == vs("(x 1)")
    check far.values.len == 0

  test "a send that doesn't take passes it on":
    let (near, far) = (Told(), Told())
    let outer = cx()
    outer.install(far.tally)
    let inner = outer.within
    inner.install(near.tally(takes = false))
    check inner.answers("!(put x 1)") == vs("taken")
    check far.values == vs("(x 1)")

  test "an object's doers are found by its kinds":
    let c = cx()
    c.install(v"(kind greeting)", Greet())
    check c.answers("!{!(kind greeting) (said hi)}") == vs("hi")
    check c.answers("!{!(kind nothing-here) (said hi)}").len == 0
    check heard == vs("!{!(kind nothing-here) (said hi)}")

  test "what doers say they do is a value":
    check answers("!(describe half)").len == 0
    let c = cx()
    c.install(native Half)
    check c.answers("!(describe half)") ==
      vs("!(struct half {exact (nim Half) (rep record)} (n number))")

suite "natives":
  test "a struct read by position may leave its trailing optionals out":
    let c = cx()
    c.install(native Span)
    check c.answers("!(span 1)") == vs("[1 nil]")
    check c.answers("!(span 1 2)") == vs("[1 2]")

  test "a marked value given as data reaches a marked parameter undone":
    let c = cx()
    c.install(native Takes)
    check c.answers("!(takes !(quote [0x00!]))") == vs("0x00!")

  test "read exactly, an argument more doesn't fit":
    let c = cx()
    c.install(native Half)
    check c.answers("!(half 8 9)").len == 0

  test "arithmetic refuses past what the host's integers hold":
    refuses answers("!(add 9223372036854775807 1)")
    refuses answers("!(mul 4611686018427387904 2)")
    refuses answers("!(add 99999999999999999999 1)")
    refuses answers("!(div 1 0)")
    answersAre "!(sub -9223372036854775808 -9223372036854775808)", "0"
    answersAre "!(sub -1 -9223372036854775808)", "9223372036854775807"
    refuses answers("!(sub 0 -9223372036854775808)")

suite "functions":
  test "a function is a value carrying the variables its body mentions":
    answersAre "!(let {k: 3} [!(fn [x] [!(mul x! k!)])])",
      "(fn [x] [!(mul x! k!)] {k: 3})"

  test "a function in a variable is applied by a marked head":
    answersAre "!(let {k: 3} [!(let !{f: !(fn [x] [!(mul x! k!)])} [!(f! 7)])])", "21"

  test "its body sees what it carries and its parameters, nothing of the caller's":
    answersAre "!(let {f: (fn [x] [!(add x! y!)] {:}) y: 1} [!(f! 2)])"
    check heard == vs("y!")

  test "a function goes anywhere a value can, and is applied there":
    let made = cx().value(v"!(let {k: 3} [!(fn [x] [!(mul x! k!)])])").get
    let landed = Value.decode(made.ce)
    let call = initRec(@[landed, num(7)], mark = true)
    check cx().value(call) == some num(21)

  test "a named function calls itself":
    answersAre "!(let !{fib: !(fn fib [n] [!(if [!(lt n! 2)] [n!] [!(add !(fib! !(sub n! 1)) !(fib! !(sub n! 2)))])])} [!(fib! 15)])", "610"

  test "bodies entered one inside another are refused past the depth":
    refuses answers("!(let !{f: !(fn f [n] [!(f! n!)])} [!(f! 1)])")

suite "rules":
  test "a call fitting a rule's example does its body, its holes bound":
    let c = cx()
    c.install(rules(vs(
      "(rule (shape !(fib n) {n}) [!(if [!(lt n! 2)] [n!] [!(add !(fib !(sub n! 1)) !(fib !(sub n! 2)))])])")))
    check c.answers("!(fib 15)") == vs("610")

  test "the first rule that answers gives its answers; readings gives every rule's":
    let c = cx()
    c.install(rules(vs(
      "(rule (shape !(fib 0) {}) [0])",
      "(rule (shape !(fib 1) {}) [1])",
      "(rule (shape !(fib n) {n}) [!(add !(fib !(sub n! 1)) !(fib !(sub n! 2)))])")))
    check c.answers("!(fib 10)") == vs("55")
    check c.answers("!(count [!(fib 1)])") == vs("1")

suite "the base vocabulary":
  test "tests answer something or nothing; there are no booleans":
    answersAre "!(lt 1 2)", "1"
    answersAre "!(lt 2 1)"
    answersAre "!(eq a a)", "a"
    answersAre "!(compare 10 9)", "gt"
    answersAre "!(compare -5 0)", "lt"

  test "if, else and case take blocks":
    answersAre "!(if [!(lt 5 3)] small big)", "big"
    answersAre "!(if [!(lt 1 3)] [!(add 1 1)])", "2"
    answersAre "!(else [!(lt 5 3)] [!(add 2 2)])", "4"
    answersAre "!(case !(compare 1 2) {lt: [less] gt: [more]})", "less"

  test "a record is made by record, since a marked one is a call":
    answersAre "!(record pair !(add 1 2) x)", "(pair 3 x)"

  test "collectors are where a stream meets a value":
    answersAre "!(all [!(add !(in [1 2 3]) 10)])", "[11 12 13]"
    answersAre "!(first [!(in [a b])])", "a"
    answersAre "!(count [!(in {a b c})])", "3"
    answersAre "!(take 2 [!(in [a b c])])", "a", "b"
    answersAre "!(sum !(range 5))", "10"

  test "a block does each form but the last once, and answers the last":
    let t = Told()
    let c = cx()
    c.install(t.tally)
    check c.answers("!(do [!(put a 1) !(put b 2) done])") == vs("done")
    check t.values == vs("(a 1)", "(b 2)")

  test "shapes fill as a search":
    answersAre "!(fill (shape (pair x y) {x y}) (pair 1 2))", "{x: 1 y: 2}"
    answersAre "!(inject (shape (pair x y) {x y}) {x: 1})", "(pair 1 y)"

suite "readings kept":
  test "a frame is read once however many hands it passes through":
    var r = reading[int](sym"width", x => x.len)
    let a = v"[1 2 3]"
    let b = a
    check r[a] == 3
    check r[b] == 3
    check r.reads == 1
    check r[v"[1 2 3]"] == 3   # equal, built apart: read again
    check r.reads == 2

  test "a marked frame is another value, read apart":
    var r = reading[bool](sym"marked", x => x.mark)
    var m = v"[1]"
    m.mark = true
    check not r[v"[1]"]
    check r[m]

suite "numbers over frames":
  proc ncx(): Cx =
    result = cx()
    result.numeric

  test "a call over whole vectors answers once":
    check ncx().answers("!(dot [2 3 -4] [5 7 2])") == vs("23")
    check ncx().answers("!(vadd [1 2] [10 20])") == vs("[11 22]")
    check ncx().answers("!(scale 3 [1 2])") == vs("[3 6]")
    check ncx().answers("!(matmul [[1 2] [3 4]] [[5 6] [7 8]])") == vs("[[19 22] [43 50]]")

  test "a vector handed to many calls is read once":
    let c = ncx()
    let before = VectorOf.reads
    check c.answers("!(let !{v: !(range 1000)} [!(add !(dot v! v!) !(vsum v!))])") ==
      vs($(332833500 + 499500))
    check VectorOf.reads - before == 1

  test "what the host can't hold is refused":
    refuses ncx().answers("!(dot [1 2] [1])")
    refuses ncx().answers("!(dot [99999999999999999999] [1])")
    refuses ncx().answers("!(vmul [4611686018427387904] [2])")

suite "edges":
  test "doers installed around a cx after it was made are in its reach":
    let root = newCx()
    let middle = root.within
    let leaf = middle.within
    middle.install(native Half)
    check toSeq(leaf.eval(v"!(half 4)")) == vs("2")

  test "a doer that has acted owns the call, refusing or not":
    let (near, far) = (Told(), Told())
    let outer = cx()
    outer.install(rules(vs("(rule (shape !(log x) {x}) [fallback])")))
    let inner = outer.within
    inner.install(near.tally)
    inner.install(rules(vs("(rule (shape !(log x) {x}) [!(put log x!) !(div 1 0)])")))
    refuses inner.answers("!(log hi)")
    check near.values == vs("(log hi)")

  test "readings bind a marked head, and pass over a doer that refuses":
    let c = cx()
    c.install(native Half)
    c.install(rules(vs("(rule (shape !(half n) {n}) [!(record ratio n! 2)])")))
    check c.answers("!(readings [!(half 7)])") == vs("(ratio 7 2)")
    check c.answers("!(let {f: (fn [x] [!(add x! 1)] {:})} [!(readings [!(f! 3)])])") == vs("4")

  test "a list and a record sharing a body are read apart":
    let items = newBuffer[Value](@[num(1), num(2)])
    var r = reading[Kind](sym"kind", x => x.kind)
    check r[initList(items)] == bList
    check r[initRec(items)] == bRec

  test "a block's forms follow as arguments do, so a block of tests is all of them":
    answersAre "!(if [!(lt 5 3) !(lt 1 3)] [yes] [no])", "no"
    answersAre "!(if [!(gt 5 0) !(lt 5 10)] [yes] [no])", "yes"
    answersAre "!(all [!(in [1 2]) !(in [a b])])", "[a b a b]"

suite "finds":
  let ages = "!{!(kind search-space) !(kind find) " &
    "(of !{!(kind search-space) (holds {(alice (age 30)) (bob (age 41))})}) " &
    "(hole p) (hole a) (where (p (age a))) (gives A)}"

  test "a find done answers what it finds":
    check answers(ages.replace("(gives A)", "(gives (p a))")).len == 2

  test "its answers cross with a call's like any argument's":
    check answers("!(all [!(add " & ages.replace("(gives A)", "(gives a)") & " 1)])") in
      [vs("[31 42]"), vs("[42 31]")]

suite "found in review":
  test "a function calling itself a hundred or more times runs":
    for n in [99, 100, 101, 150, 151, 300]:
      check answers("!(let !{f: !(fn f [n] [!(if [!(gt n! 0)] [!(f! !(sub n! 1))] [done])])} [!(f! " &
                    $n & ")])") == vs("done")

  test "readings of an unmarked value is the value, nothing done":
    let t = Told()
    let c = cx()
    c.install(t.tally)
    check c.answers("!(readings [(put x 1)])") == vs("(put x 1)")
    check t.values.len == 0

  test "an act has no other readings":
    let (near, far) = (Told(), Told())
    let outer = cx()
    outer.install(far.tally)
    let inner = outer.within
    inner.install(near.tally)
    check inner.answers("!(readings [!(put x 1)])") == vs("taken")
    check far.values.len == 0

  test "doing ended stays ended, however often pulled":
    let far = Told()
    let outer = cx()
    outer.install(far.tally)
    outer.install(rules(vs("(rule (shape !(log x) {x}) [fallback])")))
    let inner = outer.within
    inner.install(rules(vs("(rule (shape !(log x) {x}) [!(put log x!) !(lt 2 1)])")))
    let s = inner.eval(v"!(log hi)")
    check s().isNone
    check s().isNone
    check far.values == vs("(log hi)")

  test "by name, a marked dict's values are worked out":
    let c = cx()
    c.install(native Point)
    check c.answers("!(point !{x: !(add 1 2) y: 4})") == vs("[3 4]")
    check c.answers("!(point {x: !(add 1 2) y: 4})").len == 0

  test "range refuses what it can't make":
    refuses answers("!(range -9223372036854775808 1)")
    refuses answers("!(range 100000000)")
