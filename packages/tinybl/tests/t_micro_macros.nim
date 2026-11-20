import std/unittest
import tinybl/[micro, micro_macros, text]

blet "{ping serve-tcp}"
blet "{greeting: (welcome \"hi\") origin: (point 0 0)}"

type Probe = ref object of Live

template fits(pattern: string, x: untyped): bool =
  matchValue x:
  of pattern: true
  else: false

suite "bl":
  test "a splice puts a node where it stands, marked when it says so":
    let (a, b) = (bl"1", bl"(q)")
    check bl"[$a $b!]" == bl"[1 !(q)]"

  test "a splice is spelled as a Nim name, a field among them":
    type Pair = object
      left, right: Node
    let
      firstOne = bl"x"
      p = Pair(left: bl"l", right: bl"r")
    check bl"($first-one $p.left $p.right)" == bl"(x l r)"

  test "a spread puts each member of a seq in the frame it stands in":
    let xs = @[bl"a", bl"b"]
    check bl"[0 @xs 1]" == bl"[0 a b 1]"
    check bl"(q @xs!)" == bl"(q a! b!)"
    check bl"{@xs c}" == bl"{a b c}"
    let none: seq[Node] = @[]
    check bl"[@none]" == bl"[]"

  test "a doubled sigil spells the symbol with one":
    check bl"$$x" == Sym("$x")
    check bl"[@@xs &&r]" == List(@[Sym("@xs"), Sym("&r")])

  test "a sigil out of its place is refused":
    let xs = @[bl"a"]
    check not compiles(bl"@xs")
    check not compiles(bl"{k: @xs}")
    check not compiles(bl"(q &rest)")

suite "blet":
  test "a set names each symbol, spelled as a Nim name":
    check ping == bl"ping"
    check serveTcp == bl"serve-tcp"

  test "a dict names each value by its key":
    check greeting == bl"""(welcome "hi")"""
    check origin == bl"(point 0 0)"

  test "inside a proc its names stay there":
    proc local: Node =
      blet "{here}", exported = false
      here
    check local() == bl"here"

suite "matchValue":
  test "a record fits one of its head, mark and length":
    check "(q $a)".fits bl"(q 1)"
    check not "(q $a)".fits bl"(r 1)"
    check not "(q $a)".fits bl"!(q 1)"
    check not "(q $a)".fits bl"(q 1 2)"
    check not "(q $a)".fits bl"[q 1]"
    check "!(q $a)".fits bl"!(q 1)"

  test "an atom fits an equal one, mark and all":
    check "go".fits bl"go"
    check not "go".fits bl"go!"
    check not "go".fits bl"""  "go"  """
    check "\"go\"".fits bl"""  "go"  """
    check not "\"go\"".fits bl"""  "go"!  """
    check "[1 $_]".fits bl"[1 x]"
    check not "[1 $_]".fits bl"[2 x]"

  test "atoms of every kind":
    check "[5 -7 123456789012345678901234567890 0xbeef nil]".fits(
      bl"[5 -7 123456789012345678901234567890 0xbeef nil]")
    check not "[5]".fits bl"[6]"
    check not "[5]".fits bl"[5!]"
    check not "[0xbeef]".fits bl"[0xbeee]"
    check not "[123456789012345678901234567890]".fits bl"[123456789012345678901234567891]"
    check not "[nil]".fits bl"[nil!]"

  test "a hole binds what is at its place":
    let r = matchValue bl"(put (who) [1 2])":
    of "(put $q $a)": bl"[$a $q]"
    else: bl"none"
    check r == bl"[[1 2] (who)]"

  test "holes bind deep in frames and dicts":
    let got = matchValue bl"{k: [1 (q 2)] j: 3}":
    of "{k: [$_ (q $n)]}": n
    else: bl"none"
    check got == bl"2"

  test "a pattern that fits anything may come first":
    let got = matchValue bl"(a b)":
    of "$whole": whole
    else: bl"none"
    check got == bl"(a b)"
    proc only(v: Node): Node =
      matchValue v:
      of "$it": return it
    check bl"[x]".only == bl"[x]"

  test "a rest binds the members after those before it":
    let got = matchValue bl"(row a b c)":
    of "(row $first-one &others)": bl"[$firstOne @others]"
    else: bl"none"
    check got == bl"[a b c]"
    let empty = matchValue bl"(row)":
    of "(row &others)": others
    else: @[bl"none"]
    check empty.len == 0
    check "(q $_ &_)".fits bl"(q 1 2 3)"
    check not "(q $_ &_)".fits bl"(q)"
    check not "(q &_)".fits bl"!(q 1)"
    check "[&_]".fits bl"[]"

  test "with {any-mark} a value fits whatever its own mark":
    check "(q $a) {any-mark}".fits bl"(q 1)"
    check "(q $a) {any-mark}".fits bl"!(q 1)"
    check "go {any-mark}".fits bl"go!"
    check "5 {any-mark}".fits bl"5!"
    check "nil {any-mark}".fits bl"nil!"
    check not "(q (r)) {any-mark}".fits bl"(q !(r))"
    check not "(q $a) {any-mark}".fits bl"(r 1)"

  test "a marked hole fits only a marked value":
    check "($x!)".fits bl"(go!)"
    check not "($x!)".fits bl"(go)"
    check "($x)".fits bl"(go!)"

  test "$_ fits anything and binds nothing":
    check "[$_ $_]".fits bl"[1 2]"
    check "$_".fits bl"!{anything}"

  test "a dict or set fits one holding what it names":
    check "{k: $v}".fits bl"{k: 1 j: 2}"
    check not "{k: $v}".fits bl"{j: 2}"
    check not "{k: $v}".fits bl"!{k: 1}"
    check "{a}".fits bl"{a b}"
    check not "{a c}".fits bl"{a b}"
    check "{[1 2]: (q $x) z: $_}".fits bl"{z: 0 [1 2]: (q 9) a: 1}"
    check "{{a}}".fits bl"{{a} {b}}"

  test "a branch naming a Nim value fits a subject equal to it":
    proc which(v: Node): string =
      matchValue v:
      of serveTcp: "serve"
      of ping: "ping"
      of "($_)": "one"
      else: "other"
    check bl"serve-tcp".which == "serve"
    check bl"serveTcp".which == "other"
    check bl"ping".which == "ping"
    check bl"ping!".which == "other"
    check bl"(x)".which == "one"

  test "the first branch that fits runs, elif and else among them":
    proc which(v: Node, loud: bool): string =
      matchValue v:
      of "(say $words)": "said"
      elif loud: "loud"
      of "($_ $_)": "pair"
      else: "other"
    check bl"""(say "hi")""".which(true) == "said"
    check bl"(a b)".which(true) == "loud"
    check bl"(a b)".which(false) == "pair"
    check bl"[a b]".which(false) == "other"

  test "a value is matched as a node is":
    let v = Value.parse("(row {k: [1 (q 2)] j: 3} {a b} 0xbeef -7 \"t\" a b)")
    let got = matchValue v:
    of "(row {k: [$_ (q $n)]} {a} 0xbeef -7 \"t\" &rest)": bl"[$n @rest]"
    else: bl"none"
    check got == bl"[2 a b]"
    check "!(q $a)".fits Value.parse("!(q 1)")
    check not "{k: $v}".fits Value.parse("{j: 2}")

  test "a hole binds a live node, and nothing else fits one":
    let live = Probe().toNode
    let got = matchValue List(@[live]):
    of "[$x]": x
    else: bl"none"
    check got == live
    check not "[(q)]".fits List(@[live])
    check not "[$x!]".fits List(@[live])

  test "a pattern no value could fit is refused":
    let v = bl"x"
    check not compiles("{$k: 1}".fits v)
    check not compiles("{$x}".fits v)
    check not compiles("(q &r $x)".fits v)
    check not compiles("(q @xs)".fits v)
    check not compiles("(q $a $a)".fits v)
    check not compiles("(q) {fast}".fits v)
