## value literals: bl"…" builds what reading its text reads, holes
## splice through toValue, and matchValue fits a value to a pattern

import std/unittest
import bl/core

template spells(s: string, built: Value) =
  test ("spells: " & s):
    check built == readValue(s)

template fits(pattern: string, v: Value): bool =
  matchValue v:
  of pattern: true
  else: false

suite "literals":
  spells "nil", bl"nil"
  spells "-7", bl"-7"
  spells "1000", bl"1_000"
  spells "123456789012345678901234567890", bl"123456789012345678901234567890"
  spells "\"hi there\"", bl"""  "hi there"  """
  spells "'a b'", bl"'a b'"
  spells "0xdeadbeef", bl"0xdead_beef"
  spells "[1 2 3]", bl"[1 2 3]"
  spells "(foo (bar baz))", bl"(foo (bar baz))"
  spells "{foo: bar}", bl"{foo: bar}"
  spells "{:}", bl"{:}"
  spells "{foo bar}", bl"{bar foo}"
  spells "{}", bl"{}"
  spells "{foo: (bar baz) {zap}: (a [b] {c: d})}",
    bl"{foo: (bar baz) {zap}: (a [b] {c: d})}"
  spells "x!", bl"x!"
  spells "!{7}", bl"!{7}"
  spells "{x x!}", bl"{x! x}"
  spells "'$n'", bl"$$n"

suite "holes":
  let
    n = 5
    s = "s"
    xs = @[1, 2]
    v = bl"(inner 1)"
    fooBar = 9
    go = bl"go!"
  spells "[5 \"s\" [1 2] (inner 1)]", bl"[$n $s $xs $v]"
  spells "(at 9)", bl"(at $foo-bar)"
  spells "5!", bl"$n!"
  spells "(inner 1)", bl"$v"
  spells "[go!]", bl"[$go]"
  spells "{5: 5}", bl"{$n: $n}"

suite "a mark said at runtime":
  let
    n = 7
    go = bl"go"
    yes = true
  spells "!(q 7)", bl("(q $n)", yes)
  spells "(q 7)", bl("(q $n)", not yes)
  spells "go!", bl("$go", yes)
  spells "![1 2]", bl("[1 2]", true)
  test "the text says no mark of its own":
    check not compiles(bl("!(q)", true))

suite "spreads":
  let
    xs = @[1, 2]
    none: seq[int] = @[]
    v = bl"[a b!]"
  spells "[0 1 2 9]", bl"[0 @xs 9]"
  spells "(head 1 2)", bl"(head @xs)"
  spells "{1 2 3}", bl"{3 @xs}"
  spells "!(r a b! 1 2)", bl"!(r @v @xs)"
  spells "[]", bl"[@none]"
  spells "['@xs' '&xs']", bl"[@@xs &&xs]"
  test "a spread of a Value takes a list or record":
    let n = bl"5"
    expect BasslineError:
      discard bl"[@n]"

blet "{alpha beta serve-tcp}"
blet "{gamma: [1 2] delta-epsilon: (d e)}"

suite "blet":
  test "a set binds each symbol":
    check alpha == sym"alpha" and beta == sym"beta"
  test "a dict binds each value":
    check gamma == bl"[1 2]" and deltaEpsilon == bl"(d e)"

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
    proc only(v: Value): Value =
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
    check "(q &&x)".fits bl"(q &&x)"
    check "(q &&x)".fits readValue("(q '&x')")
    check not "(q &&x)".fits bl"(q 1)"

  test "with {any-mark} a value fits whatever its own mark":
    check "(q $a) {any-mark}".fits bl"(q 1)"
    check "(q $a) {any-mark}".fits bl"!(q 1)"
    check "go {any-mark}".fits bl"go!"
    check "5 {any-mark}".fits bl"5!"
    check "nil {any-mark}".fits bl"nil!"
    check not "(q (r)) {any-mark}".fits bl"(q !(r))"
    check not "(q $a) {any-mark}".fits bl"(r 1)"

  test "atoms of every kind":
    check "[5 -7 123456789012345678901234567890 0xbeef nil]".fits(
      bl"[5 -7 123456789012345678901234567890 0xbeef nil]")
    check not "[5]".fits bl"[6]"
    check not "[5]".fits bl"[5!]"
    check not "[0xbeef]".fits bl"[0xbeee]"
    check not "[123456789012345678901234567890]".fits bl"[123456789012345678901234567891]"
    check not "[nil]".fits bl"[nil!]"

  test "a marked hole fits only a marked value":
    check "($x!)".fits bl"(go!)"
    check not "($x!)".fits bl"(go)"
    check "($x)".fits bl"(go!)"

  test "$_ fits anything and binds nothing":
    check "[$_ $_]".fits bl"[1 2]"
    check "$_".fits bl"!{anything}"

  test "a hole is spelled as blet spells it":
    let got = matchValue bl"(at 3)":
    of "(at $some-place)": somePlace
    else: bl"none"
    check got == bl"3"

  test "a dict or set fits one holding what it names":
    check "{k: $v}".fits bl"{k: 1 j: 2}"
    check not "{k: $v}".fits bl"{j: 2}"
    check not "{k: $v}".fits bl"!{k: 1}"
    check "{a}".fits bl"{a b}"
    check not "{a c}".fits bl"{a b}"

  test "a branch naming a Nim value fits a subject equal to it":
    proc which(v: Value): string =
      matchValue v:
      of serveTcp: "serve"
      of alpha: "alpha"
      of "($_)": "one"
      else: "other"
    check bl"serve-tcp".which == "serve"
    check bl"serveTcp".which == "other"
    check bl"alpha".which == "alpha"
    check bl"alpha!".which == "other"
    check bl"(x)".which == "one"

  test "the first branch that fits runs, elif and else among them":
    proc which(v: Value, loud: bool): string =
      matchValue v:
      of "(say $words)": "said"
      elif loud: "loud"
      of "($_ $_)": "pair"
      else: "other"
    check bl"""(say "hi")""".which(true) == "said"
    check bl"(a b)".which(true) == "loud"
    check bl"(a b)".which(false) == "pair"
    check bl"[a b]".which(false) == "other"

  test "$$name is the symbol, not a hole":
    check "($$x)".fits bl"($$x)"
    check not "($$x)".fits bl"(x)"
