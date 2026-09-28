## ops: similar, prefixes, and shapes with holes -- extract and inject

import std/[random, unittest]
import bl/core
import bl/ops
import bl/lib/[blah, blmacro]

# ---- frameKey: the byte-key form of prefixes (core/builders) ----

func isBytePrefix(a, b: openArray[byte]): bool =
  if a.len > b.len: return false
  for i in 0 ..< a.len:
    if a[i] != b[i]: return false
  true

template key(v: untyped): seq[byte] = frameKey(bl v)

# TODO: I need to update these tests to use the generative blah stuff

# suite "frameKey":
#   test "a scalar key is its own bytes -- an exact match":
#     check key("foo") == ce(bl "foo")
#     check key(42) == ce(bl 42)
#     check key(x"a0a0") == ce(bl x"a0a0")

#   test "an empty frame key is the bare header -- the whole kind":
#     check key([]) == @[byte 0x60]
#     check key({}) == @[byte 0x90]
#     check key({:}) == @[byte 0x80]

#   test "a frame key drops one END per rightmost-spine frame":
#     check key(a()) == ce(bl a())[0 ..< ^1]
#     check key(a(b, c)) == ce(bl a(b, c))[0 ..< ^1]
#     check key(a(b())) == ce(bl a(b()))[0 ..< ^2]
#     check key(r(s(t()))) == ce(bl r(s(t())))[0 ..< ^3]
#     check key({x: 1}) == ce(bl {x: 1})[0 ..< ^1]
#     check key({x: y()}) == ce(bl {x: y()})[0 ..< ^2]

#   test "a trailing 0xA0 in the payload is not an END":
#     # (foo 0xA0): ce tail is <bytes payload A0><record END A0>; drop only
#     # the record's, never the payload byte
#     check key(foo(x"a0")) == ce(bl foo(x"a0"))[0 ..< ^1]
#     check key(foo(x"a0")) != ce(bl foo(x"a0"))[0 ..< ^2]

#   test "the view and value overloads agree":
#     for _ in 0 ..< 300:
#       let v = randValue(4)
#       check frameKey(v) == frameKey(v.toView)

#   test "law: isBytePrefix(frameKey(q), ce(e))  iff  prefixes(q, e)":
#     # randValue(4), not (3): a shallower value is orders of magnitude
#     # smaller, and frameKey re-encodes+decodes through `toView` -- the
#     # law is size-independent, so cheap samples buy more coverage.
#     for _ in 0 ..< 300:
#       let q = randValue(4)
#       let kq = frameKey(q)                    # once, not once per `e`
#       check isBytePrefix(kq, ce(q))           # reflexive: q selects itself
#       let p = randPrefix(q)
#       check isBytePrefix(frameKey(p), ce(q))  # a real prefix selects q
#       check prefixes(p, q)
#       for _ in 0 ..< 6:                       # vs arbitrary others, both ways
#         let e = randValue(4)
#         check isBytePrefix(kq, ce(e)) == prefixes(q, e)

# suite "extract":
#   test "holes bind, literals must match":
#     let file = bl shape(file(name, digest), {name, digest})
#     extracts(
#       %file,
#       file("a.txt", x"ff"),
#       {name: "a.txt", digest: x"ff"}
#     )
#     misextracts file(!name, !digest), dir("a.txt", x"ff")
#     misextracts file(!name), file("a", x"ff")
#   test "a repeated hole must agree":
#     extracts [!x, !y, !x], [1, 2, 1], {x: 1, y: 2}
#     misextracts [!x, !y, !x], [1, 2, 3]
#   test "the anonymous hole binds nothing":
#     extracts [`_!`, `_!`, !z], [1, 2, 3], {z: 3}
#   test "dicts: extra keys ignored, missing keys fail":
#     extracts {k: !v, extra: 1}, {k: [1, 2], extra: 1, more: 0}, {v: [1, 2]}
#     misextracts {k: !v}, {j: 1}
#     extracts [{x: [!h]}, 1], [{x: [5]}, 1], {h: 5}
#   test "frame marks are literal":
#     extracts !f(!x), !f(1), {x: 1}
#     misextracts !f(!x), f(1)
#   test "a head can be a hole":
#     extracts `h!`(1), foo(1), {h: foo}
#   test "hole-free sets are equality":
#     extracts {a, b}, {a, b}, {:}
#     misextracts {a, b}, {a, b, c}
#   test "any marked atom names a hole":
#     extracts !7, [1, 2], {7: [1, 2]}
#     extracts !go, !go, {go: !go}
#   test "a hole in a dict key or a set member is ambiguous":
#     ambiguous {!k: 1}, {k: 1}
#     ambiguous {!a, b}, {a, b}

# suite "inject":
#   # holes filled, unbound holes and _! kept, so filling composes
#   test "fills what is bound":
#     injects file(!name, !digest), {name: "a", digest: x"ff"}, file("a", x"ff")
#     injects file(!name, !digest), {name: "a"}, file("a", !digest)
#     injects file(!name, !digest), {:}, file(!name, !digest)
#     injects [`_!`, !x], {x: 1, `_`: 2}, [`_!`, 1]
#   test "every position, keys and members too":
#     injects {!k: !v}, {k: a, v: 1}, {a: 1}
#     injects {!x, 3}, {x: 1}, {1, 3}
#     injects !f(!x), {x: [1]}, !f([1])
#   test "composes":
#     injects f(!x), {x: !y}, f(!y)
#     check inject(inject(bl(f(!a, !b)), bl({a: 1})), bl({b: 2})) == bl(f(1, 2))

# # the laws, on generated values: punch holes into a value, extract
# # from the original, inject back

# proc unmarkAtoms(v: Value): Value =
#   ## marked atoms would read as holes, so the generated value has none
#   case v.kind
#   of bList, bRec:
#     var kids: seq[Value]
#     for c in v.items: kids.add unmarkAtoms(c)
#     result = if v.kind == bList: initList(kids, v.mark) else: initRec(kids, v.mark)
#   of bDict:
#     result = initDict(v.mark)
#     for k, val in v.dict: result.dict[unmarkAtoms(k)] = unmarkAtoms(val)
#   of bSet:
#     result = initSet(v.mark)
#     for m in v.els: result.els.incl unmarkAtoms(m)
#   else:
#     result = v
#     result.mark = false

# var rng = initRand(3)
# var holes = 0

# proc punch(v: Value, expect: var Value): Value =
#   ## the shape: some atoms in list/record positions and dict values
#   ## become holes, named in order; what they replace goes to `expect`
#   case v.kind
#   of bList, bRec:
#     var kids: seq[Value]
#     for c in v.items:
#       if c.kind notin {bList, bRec, bDict, bSet} and rng.rand(1.0) < 0.4:
#         let name = sym("h" & $holes)
#         inc holes
#         expect.dict[name] = c
#         kids.add sym(name.text, true)
#       else:
#         kids.add punch(c, expect)
#     result = if v.kind == bList: initList(kids, v.mark) else: initRec(kids, v.mark)
#   of bDict:
#     result = initDict(v.mark)
#     for k, val in v.dict:
#       result.dict[k] = punch(val, expect)
#   else:
#     result = v

# suite "laws":
#   test "extract then inject on random values":
#     for _ in 0 ..< 300:
#       let v = unmarkAtoms(randValue(3))
#       var expect = initDict()
#       let shape = punch(v, expect)
#       var b: Value
#       checkpoint($shape & " should fit " & $v)
#       check extract(shape, v, b)
#       check b == expect
#       check inject(shape, b) == v
#       check similar(inject(shape, b), v)
#     check holes > 100