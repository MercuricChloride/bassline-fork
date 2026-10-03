## queries: streams over values to compose from, and what objects
## answer, unmarked records, and what to do about them, marked records

import std/[options, unittest]
import bl/core
import bl/lib/[blmacro, blah]
import bl/queries

suite "streams over values":
  test "members and entries, in order":
    check members(bl {c, a, b}).collect == @[bl a, bl b, bl c]
    check collect(entries(bl {b: 2, a: 1})) == @[(bl a, bl 1), (bl b, bl 2)]
    check members(bl [a]).collect.len == 0          # not a set: nothing

  test "predicates and maps compose with streams":
    let s = bl {f(1), f(2, 3), g(4), x}
    check members(s).filterMap(toAnswer).map(Answer -> it.answer).collect == @[bl 1, bl 4]
    check (members(s) |> (Value -> it.isKind({bRec}) and it.hasWidth(3))).collect ==
      @[bl f(2, 3)]
    check (members(s) |> (Value -> it.isKind({bSym}) or it.hasWidth(3))).collect.len == 2

  test "a set's records under a head, and between any bounds":
    let s = bl({a(1), b(2), b(3), !b(4), c(5)}).els
    check headed(s, bl b).collect == @[bl b(2), bl b(3)]
    check headed(s, bl b, marked = true).collect == @[bl(!b(4))]
    check s.between(always, always).collect.len == 5

  test "lists or records that begin with given members, by bisecting":
    let s = readValue("{[1 2] [1 2 3] [1 3] [2] (a 1 x) (a 1) (a 2) !(a 1 y)}").els
    check s.ledBy(bList, @[bl 1]).collect == @[bl [1, 2, 3], bl [1, 2], bl [1, 3]]
    check s.ledBy(bList, @[bl 1, bl 2]).collect == @[bl [1, 2, 3], bl [1, 2]]
    check s.ledBy(bRec, @[bl a, bl 1]).collect == @[readValue("(a 1 x)"), readValue("(a 1)")]
    check s.ledBy(bRec, @[bl a, bl 1], marked = true).collect == @[readValue("!(a 1 y)")]
    check s.ledBy(bList, @[]).collect.len == 4             # the whole kind
    check s.ledBy(bRec, @[bl b]).collect.len == 0

  test "a head's records are found by bisecting, however many leaves the set has":
    var many = newBSet()
    for i in 0 ..< 500:
      many.incl initRec(@[sym("h" & $i), toValue(i)])
      many.incl initRec(@[sym("h" & $i), toValue(i)], mark = true)
    for i in [0, 7, 250, 499]:
      check headed(many, sym("h" & $i)).collect == @[initRec(@[sym("h" & $i), toValue(i)])]
      check headed(many, sym("h" & $i), marked = true).collect ==
        @[initRec(@[sym("h" & $i), toValue(i)], mark = true)]
    check headed(many, sym"absent").collect.len == 0

  test "a frame's parts, and a walk through everything inside a value":
    check readValue("(f [1 2] {k: v})").parts.collect ==
      @[bl f, bl [1, 2], bl {k: v}]
    check bl(5).parts.collect.len == 0
    let v = readValue("(f [1] {k: v})")
    check v.walk.collect == @[v, bl f, bl [1], bl 1, bl {k: v}, bl k, bl v]

  test "unique passes each value once":
    check unique(initStream(@[bl a, bl b, bl a, bl c, bl b])).collect ==
      @[bl a, bl b, bl c]

suite "objects":
  let space = readValue(
    "!{!(kind search-space) !(kind cat) (identity s) (identity 0x01) (parts [a b])}")

  test "answers are unmarked records, orders marked ones, kinds among them":
    check space.isObject
    check space.answers(IdentityQ).collect == @[bl s, bl x"01"]
    check space.answers(KindQ).collect.len == 0         # a kind is an order
    check space.kinds.collect == @[CatKind, SearchSpaceKind]   # CE order
    check space.hasKind(CatKind) and not space.hasKind(SendKind)
    check space.answer(PartsQ) == some(bl [a, b])
    check space.answer(HoldsQ).isNone                 # nothing said
    check space.answer(IdentityQ) == some(bl s)       # a reader wanting one
    check not bl({x}).isObject                        # an unmarked set is data

  test "describe writes kinds, names and answers":
    check describe([SearchSpaceKind], bl s1, initRec(@[HoldsQ, bl {}])) ==
      readValue("!{!(kind search-space) (identity s1) (holds {})}")

  test "every kind of every object is found the way any answer is":
    let objects = @[space, readValue("!{!(kind send) !(to s)}"),
                    readValue("!{!(kind bvar) (identity v)}")]
    var all = newBSet()
    for o in objects:
      for k in o.kinds: all.incl k
    check all == toBTreeSet([SearchSpaceKind, CatKind, SendKind, BVarKind])

  test "names: answers to identity; sameness is meeting; more is a union":
    check identities(space).collect == @[bl s, bl x"01"]
    check identities(bl bare).collect == @[bl bare]     # a name of its own
    check space.knownAs(bl s) and not space.knownAs(bl other)
    check sharesIdentity(space, identity(bl s, bl other))
    check not sharesIdentity(space, bl other)
    let more = space.alsoKnownAs(bl `s-v2`)
    check identities(more).collect.len == 3
    check more.kinds.collect == space.kinds.collect       # everything else kept
    check identityOf(space) == identity(bl s, bl x"01")

  test "a send's orders say where it sends":
    let s = readValue("!{!(kind send) !(to a) !(to b)}")
    check s.targets.collect == @[bl a, bl b]
    check target(bl a) == readValue("!(to a)")

template isSimilar(a, b: string): untyped =
  similar(readValue(a), readValue(b))

suite "similar":
  test "atoms by kind and mark":
    check isSimilar("1", "2")
    check isSimilar("\"a\"", "\"\"")
    check not isSimilar("a", "\"a\"")
    check not isSimilar("a!", "a")
  test "an empty frame fits any frame of its kind":
    check isSimilar("[1 2 3]", "[]")
    check isSimilar("(file a b)","(file)")
    check isSimilar("{a: 1}", "{:}")
    check isSimilar("{1 2}", "{}")
  test "lists and records: a prefix, positions by shape":
    check isSimilar("[1 x]", "[2 y]")
    check not isSimilar("[1]", "[0 0]")
    check isSimilar("(file \"n\" 0xff 42)", "(file \"\" 0xff)")
    check not isSimilar("(dir foo)", "(file)")
  test "dicts: keys required, values by shape, extras ignored":
    check isSimilar(
      "{a: 1 b: x}",
      "{a: 0}"
    )
    check not isSimilar(
      "{a: x}",
      "{a: 0}"
    )
    check not isSimilar(
      "{b: 1}",
      "{a: 0}"
    )
    check isSimilar("{a: [1 2]}", "{a: [0]}")   # the value's frame may be longer
    check not isSimilar("{a: [1]}", "{a: [0 0]}")
  test "sets: members literal":
    check isSimilar("{1 2 3}", "{2}")
    check not isSimilar("{1 2 3}", "{0}")
    check not isSimilar("{\"x\" 7}", "{\"\"}")

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
