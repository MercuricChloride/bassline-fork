## ops: similar, and shapes with holes -- extract and inject

import std/[random, unittest]
import bl/core
import bl/lib/[ops, blah, blmacro]

template fits(v, e: untyped) =
  check similar(bl(v), bl(e))

template misfits(v, e: untyped) =
  check not similar(bl(v), bl(e))

template extracts(shape, v, bindings: untyped) =
  ## the shape fits v, binding exactly bindings
  var b: Value
  check extract(bl(shape), bl(v), b)
  check b == bl(bindings)

template misextracts(shape, v: untyped) =
  var b: Value
  check not extract(bl(shape), bl(v), b)

template ambiguous(shape, v: untyped) =
  ## a hole where a value is looked up by, not matched: refused
  var b: Value
  expect ValueError:
    discard extract(bl(shape), bl(v), b)

template injects(shape, bindings, filled: untyped) =
  check inject(bl(shape), bl(bindings)) == bl(filled)

suite "similar":
  # containment. Atoms by kind and mark; lists and records a prefix,
  # positions by shape; dict keys required, values by shape, extras
  # ignored; set members literal; not symmetric
  test "atoms by kind and mark":
    fits 1, 2
    fits "a", ""
    misfits a, "a"
    misfits !a, a
  test "an empty frame fits any frame of its kind":
    fits [1, 2, 3], []
    fits file(a, b), file()
    fits {a: 1}, {:}
    fits {1, 2}, {}
  test "lists and records: a prefix, positions by shape":
    fits [1, "x", [a]], [0, "", []]
    misfits [1], [0, 0]
    fits file("n", x"ff", 42), file("", x"")
    misfits dir("n"), file("")
    fits [1, 2], [1]
    misfits [1], [1, 2]
  test "dicts: keys required, values by shape, extras ignored":
    fits {a: 1, b: "x"}, {a: 0}
    misfits {a: "x"}, {a: 0}
    misfits {b: 1}, {a: 0}
  test "sets: members literal":
    fits {1, 2, 3}, {2}
    misfits {1, 2, 3}, {0}
    misfits {"x", 7}, {""}

suite "extract":
  # literal parts equal, holes bind by name
  test "holes bind, literals must match":
    extracts file(!name, !digest), file("a.txt", x"ff"), {name: "a.txt", digest: x"ff"}
    misextracts file(!name, !digest), dir("a.txt", x"ff")
    misextracts file(!name), file("a", x"ff")
  test "a repeated hole must agree":
    extracts [!x, !y, !x], [1, 2, 1], {x: 1, y: 2}
    misextracts [!x, !y, !x], [1, 2, 3]
  test "the anonymous hole binds nothing":
    extracts [`_!`, `_!`, !z], [1, 2, 3], {z: 3}
  test "dicts: extra keys ignored, missing keys fail":
    extracts {k: !v, extra: 1}, {k: [1, 2], extra: 1, more: 0}, {v: [1, 2]}
    misextracts {k: !v}, {j: 1}
    extracts [{x: [!h]}, 1], [{x: [5]}, 1], {h: 5}
  test "frame marks are literal":
    extracts !f(!x), !f(1), {x: 1}
    misextracts !f(!x), f(1)
  test "a head can be a hole":
    extracts `h!`(1), foo(1), {h: foo}
  test "hole-free sets are equality":
    extracts {a, b}, {a, b}, {:}
    misextracts {a, b}, {a, b, c}
  test "any marked atom names a hole":
    extracts !7, [1, 2], {7: [1, 2]}
    extracts !go, !go, {go: !go}
  test "a hole in a dict key or a set member is ambiguous":
    ambiguous {!k: 1}, {k: 1}
    ambiguous {!a, b}, {a, b}

suite "inject":
  # holes filled, unbound holes and _! kept, so filling composes
  test "fills what is bound":
    injects file(!name, !digest), {name: "a", digest: x"ff"}, file("a", x"ff")
    injects file(!name, !digest), {name: "a"}, file("a", !digest)
    injects file(!name, !digest), {:}, file(!name, !digest)
    injects [`_!`, !x], {x: 1, `_`: 2}, [`_!`, 1]
  test "every position, keys and members too":
    injects {!k: !v}, {k: a, v: 1}, {a: 1}
    injects {!x, 3}, {x: 1}, {1, 3}
    injects !f(!x), {x: [1]}, !f([1])
  test "composes":
    injects f(!x), {x: !y}, f(!y)
    check inject(inject(bl(f(!a, !b)), bl({a: 1})), bl({b: 2})) == bl(f(1, 2))

# the laws, on generated values: punch holes into a value, extract
# from the original, inject back

proc unmarkAtoms(v: Value): Value =
  ## marked atoms would read as holes, so the generated value has none
  case v.kind
  of bList, bRec:
    var kids: seq[Value]
    for c in v.items: kids.add unmarkAtoms(c)
    result = if v.kind == bList: initList(kids, v.mark) else: initRec(kids, v.mark)
  of bDict:
    result = initDict(v.mark)
    for k, val in v.dict: result.dict[unmarkAtoms(k)] = unmarkAtoms(val)
  of bSet:
    result = initSet(v.mark)
    for m in v.els.keys: result.els[unmarkAtoms(m)] = true
  else:
    result = v
    result.mark = false

var rng = initRand(3)
var holes = 0

proc punch(v: Value, expect: var Value): Value =
  ## the shape: some atoms in list/record positions and dict values
  ## become holes, named in order; what they replace goes to `expect`
  case v.kind
  of bList, bRec:
    var kids: seq[Value]
    for c in v.items:
      if c.kind notin {bList, bRec, bDict, bSet} and rng.rand(1.0) < 0.4:
        let name = sym("h" & $holes)
        inc holes
        expect.dict[name] = c
        kids.add sym(name.text, true)
      else:
        kids.add punch(c, expect)
    result = if v.kind == bList: initList(kids, v.mark) else: initRec(kids, v.mark)
  of bDict:
    result = initDict(v.mark)
    for k, val in v.dict:
      result.dict[k] = punch(val, expect)
  else:
    result = v

suite "laws":
  test "extract then inject on random values":
    for _ in 0 ..< 300:
      let v = unmarkAtoms(randValue(3))
      var expect = initDict()
      let shape = punch(v, expect)
      var b: Value
      checkpoint($shape & " should fit " & $v)
      check extract(shape, v, b)
      check b == expect
      check inject(shape, b) == v
      check similar(inject(shape, b), v)
    check holes > 100
