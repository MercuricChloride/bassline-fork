import std/[unittest, options, random, sequtils]
import pkg/core
import lib/[grammar, infer]
import ./gen

# Reading a grammar out of data is guessing. These suites pin what each
# guess is, and then hold the whole thing to the one thing that is not a
# guess: whatever it says, it must admit every value it was shown.

const chainText = staticRead("../demos/chain/chain-v1.bl")

proc corpus(g: var Grammar, rule: string, n, size, seed: int): seq[Value] =
  var rng = initRand(seed)
  let pr = g.productivity
  let p = g.rulePattern(rule)
  for _ in 0 ..< n:
    let v = g.generate(pr, p, rng, size)
    if v.isSome:
      result.add v.get

proc inferred(vs: seq[Value], cfg = defaults()): Grammar =
  load(infer(vs, cfg))

proc rules(v: Value): seq[string] =
  for (k, _) in v.tail[0].entries:
    result.add string(k.text)

# ================ THE ONE THING THAT IS NOT A GUESS ================

suite "soundness":
  test "it admits every value it was shown":
    var chain = readGrammar(chainText)
    for rule in ["tx", "block", "account", "ledger", "start"]:
      let vs = chain.corpus(rule, 500, 24, 3)
      check vs.len > 400
      let shape = infer(vs)
      check conforms(shape, vs) == vs.len

  test "whatever a stranger's data says, the answer loads and holds":
    # the load-bearing property: grammars nobody wrote, over corpora
    # nobody curated. An inference that misses its own corpus is a bug,
    # and an inference that will not load is a worse one
    var rng = initRand(0x1FE2)
    var checked = 0
    for i in 0 ..< 300:
      var f = initFeed(newSeqWith(48, byte rng.rand(255)))
      var g: Grammar
      try:
        g = load(f.genGrammarValue())
      except GrammarError:
        continue
      var vs: seq[Value]
      let pr = g.productivity
      for name in g.ruleNames:
        for size in [0, 6, 16]:
          let v = g.generate(pr, g.rulePattern(name), rng, size)
          if v.isSome:
            vs.add v.get
      if vs.len == 0:
        continue
      let shape = infer(vs)
      discard load(shape) # must be a grammar, or this raises
      check conforms(shape, vs) == vs.len
      inc checked
    check checked > 100

  test "and over values that answer to no grammar at all":
    var rng = initRand(0x0DDBA11)
    for _ in 0 ..< 60:
      var f = initFeed(newSeqWith(64, byte rng.rand(255)))
      var vs: seq[Value]
      for _ in 0 ..< 25:
        vs.add f.genValue(3)
      let shape = infer(vs)
      discard load(shape)
      check conforms(shape, vs) == vs.len

# ================ WHAT EACH GUESS IS ================

suite "vocabulary or a name":
  test "a value that repeats is vocabulary":
    var vs: seq[Value]
    for i in 0 ..< 60:
      vs.add record(sym"file", sym(["gzip", "tarball", "none"][i mod 3]))
    var g = inferred(vs)
    check g.matches("file", record(sym"file", sym"gzip"))
    check not g.matches("file", record(sym"file", sym"brotli"))

  test "a value that never repeats is a name":
    var vs: seq[Value]
    for i in 0 ..< 60:
      vs.add record(sym"user", sym("u" & $i))
    var g = inferred(vs)
    check g.matches("user", record(sym"user", sym"someone-else"))

  test "too many distinct values is a name too, however they repeat":
    var vs: seq[Value]
    for i in 0 ..< 200:
      vs.add record(sym"tag", sym("t" & $(i mod 40)))
    var g = inferred(vs, Settings(enumMax: 16, enumRepeat: 2, positionalMax: 8,
      mapRatio: 3, litCap: 512))
    check g.matches("tag", record(sym"tag", sym"unseen"))

suite "what stays exact":
  test "a payload length that never varies is pinned":
    var vs: seq[Value]
    for i in 0 ..< 40:
      vs.add record(sym"key", bytes(newSeqWith(32, byte i)))
    var g = inferred(vs)
    check g.matches("key", record(sym"key", bytes(newSeqWith(32, byte 9))))
    check not g.matches("key", record(sym"key", bytes(newSeqWith(31, byte 9))))

  test "a payload length that varies is not":
    var vs: seq[Value]
    for i in 0 ..< 40:
      vs.add record(sym"blob", bytes(newSeqWith(i mod 5, byte i)))
    var g = inferred(vs)
    check g.matches("blob", record(sym"blob", bytes(newSeqWith(19, byte 1))))

  test "a mark is kept, and mixed marks widen to either":
    var allMarked, mixed: seq[Value]
    for i in 0 ..< 20:
      allMarked.add record(sym"run", mark(list(num($i))))
      mixed.add record(sym"run", mark(list(num($i))))
      mixed.add record(sym"run", list(num($i)))
    var m = inferred(allMarked)
    check m.matches("run", record(sym"run", mark(list(num"5"))))
    check not m.matches("run", record(sym"run", list(num"5")))
    var b = inferred(mixed)
    check b.matches("run", record(sym"run", mark(list(num"5"))))
    check b.matches("run", record(sym"run", list(num"5")))

  test "an empty frame says it is empty, and does not widen to any":
    # a bare frame operator means any frame of that kind; an inference
    # that spelled it that way would claim far more than it saw
    var vs: seq[Value]
    for _ in 0 ..< 20:
      vs.add record(sym"holder", list(), values.set(newSeq[Value]()), dict(@[]))
    var g = inferred(vs)
    check g.matches("holder", record(sym"holder", list(), values.set(newSeq[Value]()),
      dict(@[])))
    check not g.matches("holder",
      record(sym"holder", list(num"1"), values.set(newSeq[Value]()), dict(@[])))
    check not g.matches("holder",
      record(sym"holder", list(), values.set(sym"a"), dict(@[])))

suite "shapes and maps":
  test "a key seen every time is required, one seen sometimes is not":
    var vs: seq[Value]
    for i in 0 ..< 30:
      if i mod 3 == 0:
        vs.add dict(@[(sym"name", text"a"), (sym"zip", sym"gzip")])
      else:
        vs.add dict(@[(sym"name", text"a")])
    var g = inferred(vs)
    check g.matches(dict(@[(sym"name", text"x")]))
    check g.matches(dict(@[(sym"name", text"x"), (sym"zip", sym"gzip")]))
    check not g.matches(dict(@[(sym"zip", sym"gzip")]))

  test "a dictionary whose keys keep changing is a map":
    var vs: seq[Value]
    for i in 0 ..< 40:
      vs.add dict(@[(sym("k" & $i), num($i)), (sym("j" & $i), num($i))])
    var g = inferred(vs)
    # quantified, so a key it never saw is still a key
    check g.matches(dict(@[(sym"brand-new", num"7")]))

  test "a record that grew a field still admits what came before it":
    var vs: seq[Value]
    for i in 0 ..< 30:
      if i mod 2 == 0:
        vs.add record(sym"row", num($i), text"x")
      else:
        vs.add record(sym"row", num($i), text"x", sym("tail" & $i))
    var g = inferred(vs)
    check g.matches("row", record(sym"row", num"1", text"y"))
    check g.matches("row", record(sym"row", num"1", text"y", sym"other"))
    check not g.matches("row", record(sym"row", num"1"))

suite "naming":
  test "a record head earns a rule, and recursion crosses the frame":
    var vs = @[
      record(sym"node", num"1", list()),
      record(sym"node", num"2", list(record(sym"node", num"3", list()))),
    ]
    let shape = infer(vs)
    check "node" in shape.rules
    var g = load(shape)
    check g.matches("node",
      record(sym"node", num"9", list(record(sym"node", num"8", list()))))

  test "a head that cannot be a rule name is spelled where it stands":
    var vs: seq[Value]
    for i in 0 ..< 20:
      vs.add record(num"1", sym("a" & $i))
    let shape = infer(vs)
    check shape.rules == @["start"]
    check conforms(shape, vs) == vs.len

  test "a head spelled `start` does not take the start rule's name":
    var vs: seq[Value]
    for _ in 0 ..< 10:
      vs.add record(sym"start", num"1")
    let shape = infer(vs)
    check "start" in shape.rules
    check conforms(shape, vs) == vs.len

suite "determinism":
  test "the same corpus spells the same grammar, in any order":
    var chain = readGrammar(chainText)
    var vs = chain.corpus("start", 400, 22, 77)
    let once = infer(vs)
    var rng = initRand(5)
    rng.shuffle(vs)
    check infer(vs) == once
    rng.shuffle(vs)
    check infer(vs) == once

# ================ HOW WELL IT GENERALISES ================

suite "generalisation, measured":
  test "what it learns from half, it admits of the other half":
    var chain = readGrammar(chainText)
    let vs = chain.corpus("start", 2000, 24, 42)
    let cut = vs.len div 2
    let shape = infer(vs[0 ..< cut])
    check conforms(shape, vs[cut ..< vs.len]) == vs.len - cut

  test "and what it builds, the grammar it was learned from admits":
    # the round trip closes both ways: recall above, precision here
    var chain = readGrammar(chainText)
    let vs = chain.corpus("start", 1500, 24, 8)
    var learned = load(infer(vs))
    var rng = initRand(19)
    let pr = learned.productivity
    var built, kept = 0
    for _ in 0 ..< 800:
      let v = learned.generate(pr, learned.rulePattern("start"), rng, 24)
      if v.isNone:
        continue
      inc built
      if chain.matches("start", v.get):
        inc kept
    check built > 500
    check kept == built

  test "a corpus with no variety yields a grammar with no generality":
    # honest about the failure mode: vocabulary generalises exactly as
    # far as what it was shown does. One symbol seen fifty times is one
    # word, and the inference says so
    var vs: seq[Value]
    for _ in 0 ..< 50:
      vs.add record(sym"ping", sym"ok", num"1")
    var g = inferred(vs)
    check g.matches("ping", record(sym"ping", sym"ok", num"1"))
    check not g.matches("ping", record(sym"ping", sym"fine", num"1"))
    # content, though, is never frozen by a sample that did not vary
    check g.matches("ping", record(sym"ping", sym"ok", num"99"))
