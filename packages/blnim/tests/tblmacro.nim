import std/unittest
import bl/core
import bl/lib/blmacro

template spells(s: string, body: untyped) =
  test ("spells: " & s):
    let 
      macroValue = bl(body)
      val = readValue(s)
    check val == macroValue

suite "basic atoms":
  spells "nil": nil
  spells "42": 42
  spells "-7": -7
  spells "1000": 1_000
  spells "123": n"123"
  spells "\"hi there\"":
    "hi there"
  spells "foo": foo
  spells "type": `type`
  spells "'a b'": s"a b"
  spells "\"raw\"": t"raw"
  spells "0xdeadbeef": x"dead_beef"
  spells "0x": x""
  spells "0x726177": b"raw"

suite "lists":
  spells "[1 2 3]":
    [1, 2, 3]
  spells "[]": []

suite "records":
  spells "(foo)":
    foo()
  spells "(foo bar baz)":
    foo(bar, baz)
  spells "(foo (bar baz))":
    foo bar baz

suite "dicts":
  spells "{foo: bar}":
    {foo: bar}
  spells "{:}":
    {:}

suite "sets":
  spells "{foo bar}":
    {foo, bar}
  spells "{}":
    {}

suite "frames":
  spells"""{ 
      foo: (bar baz)
      {zap}: (a [b] {c: d})
    }""":
    {
      foo: bar baz,
      {zap}: a([b], {c: d})
    }

suite "marks":
  spells "x!": !x
  spells "x!": `x!`
  spells "42!": !42
  spells "!{7}": !{7}
  spells "![a b]": ![a, b]
  spells "{x x!}": {x, !x}

suite "spreads & slices":
  let 
    n = 5
    s = "s"
    xs = @[1,2]
    v = bl: inner(1)
  spells "[5 \"s\" [1 2] (inner 1)]":
    [%n, %s, %xs, %v]
  spells "[0 1 2 9]":
    [0, %%xs, 9]
  spells "(head 1 2)":
    head(%%xs)
  spells "{1 2}":
    {%%xs}
  spells "5!":
    !%n
  spells "(inner 1)":
    %v