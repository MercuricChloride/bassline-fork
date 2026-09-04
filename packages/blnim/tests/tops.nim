## ops: similar, and shapes with holes -- extract and inject
import std/[strutils, random]
import pkg/core
import lib/ops
import ./corpus

proc s(v, e: string): bool = similar(readValue(v), readValue(e))

# similar: containment. Atoms by kind and mark; lists and records a
# prefix, positions by shape; dict keys required, values by shape,
# extras ignored; set members literal; not symmetric
for c in cases(): doAssert similar(c.value, c.value), c.name
doAssert s("1", "2") and s("\"a\"", "\"\"") and not s("a", "\"a\"") and not s("a!", "a")
doAssert s("[1 2 3]", "[]") and s("(file a b)", "(file)") and s("{a: 1}", "{:}") and s("{1 2}", "{}")
doAssert s("[1 \"x\" [a]]", "[0 \"\" []]") and not s("[1]", "[0 0]")
doAssert s("(file \"n\" 0xff 42)", "(file \"\" 0x)") and not s("(dir \"n\")", "(file \"\")")
doAssert s("{a: 1 b: \"x\"}", "{a: 0}") and not s("{a: \"x\"}", "{a: 0}") and not s("{b: 1}", "{a: 0}")
doAssert s("{1 2 3}", "{2}") and not s("{1 2 3}", "{0}") and not s("{\"x\" 7}", "{\"\"}")
doAssert s("[1 2]", "[1]") and not s("[1]", "[1 2]")

# extract: literal parts equal, holes bind by name
proc fit(shape, v: string): (bool, Value) =
  var b: Value
  result[0] = extract(readValue(shape), readValue(v), b)
  result[1] = b
proc bound(shape, v: string): string =
  let (ok, b) = fit(shape, v)
  if ok: $b else: "no"

doAssert bound("(file name! digest!)", "(file \"a.txt\" 0xff)") == "{name: \"a.txt\" digest: 0xff}"
doAssert bound("(file name! digest!)", "(dir \"a.txt\" 0xff)") == "no"          # head literal
doAssert bound("(file name!)", "(file \"a\" 0xff)") == "no"                    # arity strict
doAssert bound("[x! y! x!]", "[1 2 1]") == "{x: 1 y: 2}"                       # repeated hole agrees
doAssert bound("[x! y! x!]", "[1 2 3]") == "no"
doAssert bound("[_! _! z!]", "[1 2 3]") == "{z: 3}"                            # anonymous binds nothing
doAssert bound("{k: v! extra: 1}", "{k: [1 2] extra: 1 more: 0}") == "{v: [1 2]}"   # extra keys ignored
doAssert bound("{k: v!}", "{j: 1}") == "no"                                    # missing key
doAssert bound("!(f x!)", "!(f 1)") == "{x: 1}" and bound("!(f x!)", "(f 1)") == "no"   # frame marks literal
doAssert bound("(h! 1)", "(foo 1)") == "{h: foo}"                              # a head can be a hole
doAssert bound("{a b}", "{a b}") == "{:}" and bound("{a b}", "{a b c}") == "no"   # hole-free sets: equality
doAssert bound("7!", "[1 2]") == "{7: [1 2]}"                                  # any marked atom names a hole
doAssert bound("go!", "go!") == "{go: go!}"                                    # a marked atom in the value is what a hole sees
# a hole in a dict key or a set member is ambiguous: refused, not matched
for (bad, v) in [("{k!: 1}", "{k: 1}"), ("{a! b}", "{a b}")]:
  var b: Value
  try:
    discard extract(readValue(bad), readValue(v), b)
    doAssert false, "accepted an ambiguous shape: " & bad
  except ValueError:
    discard
doAssert bound("[{x: [h!]} 1]", "[{x: [5]} 1]") == "{h: 5}"                   # a hole in a dict value is fine

# inject: holes filled, unbound holes and _! kept, so filling composes
proc fill(shape, b: string): string = $inject(readValue(shape), readValue(b))
doAssert fill("(file name! digest!)", "{name: \"a\" digest: 0xff}") == "(file \"a\" 0xff)"
doAssert fill("(file name! digest!)", "{name: \"a\"}") == "(file \"a\" digest!)"
doAssert fill("(file name! digest!)", "{:}") == "(file name! digest!)"
doAssert fill("[_! x!]", "{x: 1 _: 2}") == "[_! 1]"
doAssert fill("{k!: v!}", "{k: a v: 1}") == "{a: 1}"                           # every position, keys too
doAssert fill("{x! 3}", "{x: 1}") == "{1 3}"
doAssert fill("!(f x!)", "{x: [1]}") == "!(f [1])"
doAssert fill("(f x!)", "{x: y!}") == "(f y!)"                                 # a binding may itself be a hole
doAssert fill(fill("(f a! b!)", "{a: 1}"), "{b: 2}") == "(f 1 2)"

# the laws, on generated values: punch holes into a value, extract
# from the original, inject back
proc unmarkAtoms(v: Value): Value =
  ## marked atoms would read as holes, so the generated value has none
  case v.kind
  of bList, bRec:
    var kids: seq[Value]
    for c in v.items: kids.add unmarkAtoms(c)
    result = if v.kind == bList: initList(kids, v.marked) else: initRec(kids, v.marked)
  of bDict:
    result = initDict(v.marked)
    for k, val in v.dict: result.dict[unmarkAtoms(k)] = unmarkAtoms(val)
  of bSet:
    result = initSet(v.marked)
    for m in v.els.keys: result.els[unmarkAtoms(m)] = true
  else:
    result = v
    result.marked = false

var rng = initRand(3)
var holes = 0
proc punch(v: Value, expect: var Value): Value =
  ## the shape: some atoms in list/record positions and dict values
  ## become holes, named in order; what they replace goes to `expect`
  case v.kind
  of bList, bRec:
    var kids: seq[Value]
    for i, c in v.items:
      if c.kind notin {bList, bRec, bDict, bSet} and rng.rand(1.0) < 0.4:
        let name = sym("h" & $holes)
        inc holes
        expect.dict[name] = c
        kids.add sym(name.text, true)
      else:
        kids.add punch(c, expect)
    result = if v.kind == bList: initList(kids, v.marked) else: initRec(kids, v.marked)
  of bDict:
    result = initDict(v.marked)
    for k, val in v.dict:
      result.dict[k] = punch(val, expect)
  else:
    result = v

var g = initValueGen(23)
for _ in 0 ..< 300:
  let v = unmarkAtoms(g.genValue(3))
  var expect = initDict()
  let shape = punch(v, expect)
  var b: Value
  doAssert extract(shape, v, b), $shape & " should fit " & $v
  doAssert b == expect, $b & " vs " & $expect
  doAssert inject(shape, b) == v, $shape
  doAssert similar(v, v) and similar(inject(shape, b), v)
doAssert holes > 100
echo "tops ok"
