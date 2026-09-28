import std/[unittest]
import bl/[core, ops]
import bl/lib/[blmacro, blah]


template isPrefix(a, b: untyped) =
  check prefixes(bl(a), bl(b))

template notPrefix(a, b: untyped) =
  check not prefixes(bl(a), bl(b))

suite "prefixes":
  # a is what b's encoding yields when stopped early; a leading run of
  # members positionally, the last itself a prefix; scalars atomic;
  # dict / set by canonical order, not inclusion
  test "records and lists: a leading run, positionally":
    isPrefix foo(bar), foo(bar, baz)
    isPrefix foo(), foo(bar, baz)
    isPrefix foo(bar), foo(bar)             # reflexive
    notPrefix foo(bar, baz), foo(bar)
    isPrefix [1, 2], [1, 2, 3]
    notPrefix [1, 3], [1, 2, 3]
    notPrefix [2], [1, 2, 3]
  test "kind and mark must agree":
    notPrefix [foo, bar], foo(bar)
    notPrefix a(), [a]
    notPrefix !a(), a(b)
    isPrefix !a(), !a(b)
    isPrefix !5, !5
    notPrefix !5, 5
  test "scalars are atomic":
    isPrefix 1, 1
    notPrefix 1, 2
    notPrefix "foo", "foobar"
    notPrefix 0x12, 0x1234
    isPrefix nil, nil
    notPrefix nil, 1
    notPrefix ab, abc
  test "an empty frame prefixes any frame of its kind":
    isPrefix [], [1, 2, 3]
    isPrefix [], []
    isPrefix {:}, {a: 1, b: 2}
    isPrefix {}, {1, 2, 3}
    notPrefix [], {1, 2}
  test "deep: the last member may itself be a prefix":
    isPrefix h(x()), h(x(y), z)
    isPrefix h(x()), h(x(y))                # same arity, last truncated
    isPrefix [a, [b]], [a, [b, c], d]
    notPrefix [[b], a], [[b, c], a]         # a non-last member diverges
    isPrefix r(s(t())), r(s(t(u)), v)
  test "dicts: a leading run in canonical key order, not a subset":
    isPrefix {a: 1}, {a: 1, b: 2}
    isPrefix {a: 1, b: 2}, {a: 1, b: 2, c: 3}
    notPrefix {b: 2}, {a: 1, b: 2}
    notPrefix {a: 2}, {a: 1, b: 2}
    isPrefix {a: x()}, {a: x(y), b: 2}
  test "sets: a leading run in canonical order, not a subset":
    isPrefix {1, 2}, {1, 2, 3}
    notPrefix {1, 3}, {1, 2, 3}
    notPrefix {3}, {1, 2, 3}
    isPrefix {}, {1, 2, 3}
  test "a proper prefix sorts strictly after the whole":
    check cmp(bl foo(bar), bl foo(bar, baz)) > 0
    check cmp(bl foo(), bl foo(bar, baz)) > 0
    check cmp(bl [1, 2], bl [1, 2, 3]) > 0

suite "prefixes: laws on generated values":
  test "a truncation prefixes the whole and sorts at or after it":
    for _ in 0 ..< 400:
      let v = randValue(3)
      let p = randPrefix(v)
      checkpoint($p & " should prefix " & $v)
      check prefixes(p, v)
      check cmp(p, v) >= 0
      if p != v:
        check cmp(p, v) > 0
        check not prefixes(v, p)
  test "reflexive, and transitive down a chain":
    for _ in 0 ..< 200:
      let v = randValue(3)
      check prefixes(v, v)
      let p = randPrefix(v)
      let q = randPrefix(p)
      check prefixes(q, p)
      check prefixes(p, v)
      check prefixes(q, v)      # transitivity