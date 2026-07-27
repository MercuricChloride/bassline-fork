import std/[unittest, random, sequtils, strutils]
import pkg/core
import lib/[grammar, read]
import ./gen

# ================ THE DIALECT SHAPES ================
# The eleven shapes tdialect.nim exercises, spelled as a grammar value
# and loaded. The suites freeze the corpus verdicts against it — these
# assertions are the (grammar, value, verdict) conformance triples.
# dialect.nim is untouched.

const DialectNames = [
  "fileinfo", "file", "directory", "fsentry", "digest", "keypair", "signature",
  "signed", "dec", "big", "pinned",
]

const spelledDialect = readValue"""
!(grammar {
  start: digest!
  digest: (digest !(sym) !(bytes))
  fileinfo: {name: !(? !(text)) zip: !(? !(or gzip tarball))}
  file: (file !(bytes) !(or nil fileinfo!))
  directory: (directory {!(* fsentry!)} !(or nil fileinfo!))
  fsentry: !(or file! directory!)
  keypair: (keypair eddsa-blake2b !(bytes 32) !(bytes 32))
  signature: (signature eddsa-blake2b !(bytes 64) !(bytes 32))
  signed: (signed !(anymark !(any)) signature!)
  dec: (dec !(num) !(num))
  big: (big !(num))
  pinned: {algo: !(sym) content-type: !(? !(sym))}
})
"""

proc dialects(): Grammar =
  load(spelledDialect)

let
  payload = @[byte 1, 2, 3]
  seed32 = newSeqWith(32, byte 7)
  pub32 = newSeqWith(32, byte 9)
  sig64 = newSeqWith(64, byte 4)
  fileV = record(sym"file", bytes(payload), nilValue())
  fileInfoV = dict(@[(sym"name", text"a.txt"), (sym"zip", sym"gzip")])
  fileFullV = record(sym"file", bytes(payload), fileInfoV)
  dirV = record(sym"directory", values.set(fileV), nilValue())
  nestedDirV = record(sym"directory", values.set(fileV, dirV), nilValue())
  digestV = record(sym"digest", sym"sha256", bytes(seed32))
  keypairV = record(sym"keypair", sym"eddsa-blake2b", bytes(seed32), bytes(pub32))
  signatureV = record(sym"signature", sym"eddsa-blake2b", bytes(sig64), bytes(pub32))
  greeting = mark(record(sym"greet", text"hello"))
  signedV = record(sym"signed", greeting, signatureV)
  decV = record(sym"dec", num"15", num"-1")
  hugeDecV = record(sym"dec", num"99999999999999999999999", num"0")
  bigV = record(sym"big", num"99999999999999999999999")
  pinnedV = dict(@[(sym"algo", sym"sha256"), (sym"content-type", sym"text")])

suite "the dialect shapes":
  test "classification freezes the corpus":
    var g = dialects()
    check g.readings(fileV, DialectNames).accepted == @["file", "fsentry"]
    check g.readings(fileFullV, DialectNames).accepted == @["file", "fsentry"]
    check g.readings(fileInfoV, DialectNames).accepted == @["fileinfo"]
    check g.readings(dict(@[]), DialectNames).accepted == @["fileinfo"]
    check g.readings(dirV, DialectNames).accepted == @["directory", "fsentry"]
    check g.readings(nestedDirV, DialectNames).accepted == @["directory", "fsentry"]
    check g.readings(digestV, DialectNames).accepted == @["digest"]
    check g.readings(keypairV, DialectNames).accepted == @["keypair"]
    check g.readings(signatureV, DialectNames).accepted == @["signature"]
    check g.readings(signedV, DialectNames).accepted == @["signed"]
    check g.readings(decV, DialectNames).accepted == @["dec"]
    check g.readings(bigV, DialectNames).accepted == @["big"]
    check g.readings(pinnedV, DialectNames).accepted == @["pinned"]
    check g.readings(greeting, DialectNames).accepted.len == 0
    check g.readings(num"42", DialectNames).accepted.len == 0

  test "the start rule speaks for the grammar":
    var g = dialects()
    check g.matches(digestV)
    check not g.matches(keypairV)

  test "keypair, exactly dialect.nim's refusals":
    var g = dialects()
    check g.matches("keypair", keypairV)
    # wrong scheme literal
    check not g.matches(
      "keypair", record(sym"keypair", sym"rsa", bytes(seed32), bytes(pub32))
    )
    # wrong head
    check not g.matches(
      "keypair", record(sym"keypare", sym"eddsa-blake2b", bytes(seed32), bytes(pub32))
    )
    # wrong seed size
    check not g.matches(
      "keypair",
      record(sym"keypair", sym"eddsa-blake2b", bytes(seed32[0 ..< 31]), bytes(pub32)),
    )
    # extra field: the shape is closed
    check not g.matches(
      "keypair",
      record(sym"keypair", sym"eddsa-blake2b", bytes(seed32), bytes(pub32), nilValue()),
    )
    # missing field
    check not g.matches(
      "keypair", record(sym"keypair", sym"eddsa-blake2b", bytes(seed32))
    )

  test "record Option slots are explicit nil, not elided arity":
    var g = dialects()
    check not g.matches("file", record(sym"file", bytes(payload)))

  test "dict shapes are closed and required keys required":
    var g = dialects()
    check not g.matches("fileinfo", dict(@[(sym"name", text"x"), (sym"extra", num"1")]))
    check not g.matches("pinned", dict(@[(sym"content-type", sym"text")]))

  test "enums are symbol vocabulary":
    var g = dialects()
    check not g.matches("fileinfo", dict(@[(sym"zip", sym"bogus")]))
    check not g.matches("fileinfo", dict(@[(sym"zip", text"gzip")]))

  test "kind confusion is refused":
    var g = dialects()
    check not g.matches("digest", record(sym"digest", text"sha256", bytes(payload)))
    check not g.matches("file", record(sym"file", list(num"1"), nilValue()))

  test "marks are refused in inert slots, carried by any(mrAny)":
    var g = dialects()
    check not g.matches("digest", mark(digestV))
    check not g.matches(
      "digest", record(sym"digest", mark(sym"sha256"), bytes(payload))
    )
    # signedV's payload is marked and passes through any(mrAny)
    check g.matches("signed", signedV)

  test "range fitting is extraction's job, not recognition's":
    # dialect.nim refuses (dec 99..9 0) because int overflows; the
    # grammar speaks only of number-ness. Deliberate divergence.
    var g = dialects()
    check g.matches("dec", hugeDecV)

suite "openness":
  test "open records accept trailing extras":
    var g = initGrammar()
    let fields = [g.kindOf({bSym}), g.kindOf({bBytes})]
    g.rule "closed", g.rec(sym"digest", fields[0], fields[1])
    g.rule "open", g.openRec(sym"digest", fields[0], fields[1])
    g.seal()
    let extra = record(sym"digest", sym"sha256", bytes(payload), num"1", mark(sym"go"))
    check g.matches("open", digestV)
    check g.matches("open", extra)
    check g.matches("closed", digestV)
    check not g.matches("closed", extra)

  test "open dictionaries accept unknowns at every gap":
    var g = initGrammar()
    g.rule "open", g.openDict([(sym"algo", g.kindOf({bSym}))])
    g.rule "closed", g.dictOf([(sym"algo", g.kindOf({bSym}))])
    g.seal()
    # canonical order sorts syms by payload length first, so "zz" lands
    # before "algo", "extra" between "algo" and "content-type", and a
    # thirteen-character key after "content-type"
    let before = dict(@[(sym"zz", num"1"), (sym"algo", sym"sha256")])
    let between = dict(@[(sym"algo", sym"sha256"), (sym"extra", num"1")])
    let after = dict(@[(sym"algo", sym"sha256"), (sym"aaaaaaaaaaaaa", num"1")])
    let everywhere = dict(
      @[
        (sym"zz", num"1"),
        (mark(sym"go"), num"2"),
        (sym"algo", sym"sha256"),
        (sym"content-type", sym"text"),
        (sym"extra", mark(num"3")),
        (sym"aaaaaaaaaaaaa", num"4"),
      ]
    )
    for v in [before, between, after, everywhere]:
      check g.matches("open", v)
      check not g.matches("closed", v)
    check g.matches("closed", dict(@[(sym"algo", sym"sha256")]))
    # a required key of the wrong kind is not saved by openness
    check not g.matches("open", dict(@[(sym"algo", num"5")]))

  test "open dictionaries refuse optional entries":
    # the unknown-entry rest already admits any entry, so an optional
    # known one demands nothing: {x: "wrong"} would pass as an unknown.
    # Saying "any entry except these keys" is outside the algebra, so
    # the option is refused rather than silently vacuous
    var g = initGrammar()
    expect GrammarError:
      discard g.openDict([], optional = [(sym"x", g.kindOf({bNum}))])

  test "set shapes, closed and open":
    var g = initGrammar()
    g.rule "closed", g.setOf([sym"file", sym"pinned"])
    g.rule "open", g.openSet([sym"file", sym"pinned"])
    g.seal()
    let exact = values.set(sym"file", sym"pinned")
    check g.matches("closed", exact)
    check g.matches("open", exact)
    # unknowns land before, between, and after the known members in
    # canonical order (nums before syms, inert before marked)
    let grown = values.set(
      num"1", sym"zz", sym"file", sym"pinned", sym"aaaaaaaaaaaaa", mark(sym"go")
    )
    check g.matches("open", grown)
    check not g.matches("closed", grown)
    # required members are not saved by openness
    check not g.matches("open", values.set(sym"file"))

suite "sealing":
  test "unguarded recursion is refused":
    var g = initGrammar()
    g.rule "r", g.choice(g.refTo("r"), g.kindOf({bNum}))
    expect GrammarError:
      g.seal()

  test "same-level recursion is refused even when guarded":
    # S := empty | a S b consumes before it recurs, but it counts among
    # siblings: aⁿbⁿ has no finite automaton, so residuals grow without
    # bound and the algebra's questions stop being answerable. The
    # sibling layer stays regular: recursion must cross a frame
    var g = initGrammar()
    g.rule "s",
      g.choice(g.empty, g.group(g.lit(sym"a"), g.refTo("s"), g.lit(sym"b")))
    g.rule "t", g.frame(bList, g.refTo("s"))
    try:
      g.seal(start = "t")
      check false
    except GrammarError as e:
      check "cross a frame" in e.msg

  test "sealing is a phase boundary":
    var g = initGrammar()
    g.rule "r", g.kindOf({bNum})
    g.seal(start = "r")
    expect AssertionDefect:
      g.rule "late", g.star(g.kindOf({bNum}))
    expect AssertionDefect:
      discard g.refTo("ghost")
    check g.matches(num"1") # still the grammar that sealed

  test "recursion through frames is the value space's own":
    var g = initGrammar()
    g.rule "tree", g.frame(bList, g.star(g.refTo("tree")))
    g.seal(start = "tree")
    check g.matches(list(list(), list(list(), list())))
    check not g.matches(list(num"1"))
    check not g.matches(num"1")

  test "undefined rules are refused":
    var g = initGrammar()
    g.rule "a", g.refTo("ghost")
    expect GrammarError:
      g.seal()

  test "an unknown start is refused":
    var g = initGrammar()
    g.rule "a", g.kindOf({bNum})
    expect GrammarError:
      g.seal(start = "nope")

  test "odd dictionary parity is refused":
    var g = initGrammar()
    g.rule "bad", g.frame(bDict, g.star(g.any(mrAny)))
    expect GrammarError:
      g.seal()

  test "mixed dictionary parity is refused":
    var g = initGrammar()
    g.rule "bad",
      g.frame(bDict, g.choice(g.entry(g.any(mrAny), g.any(mrAny)), g.any(mrAny)))
    expect GrammarError:
      g.seal()

  test "even parity through a rule is fine":
    var g = initGrammar()
    g.rule "entries", g.restEntries()
    g.rule "d", g.frame(bDict, g.refTo("entries"))
    g.seal()
    check g.matches("d", dict(@[(sym"a", num"1")]))

  test "defining a rule twice is refused":
    var g = initGrammar()
    g.rule "r", g.kindOf({bNum})
    expect GrammarError:
      g.rule "r", g.kindOf({bText})

suite "refusal":
  test "judgment refuses when the budget is spent":
    var g = dialects()
    expect BudgetError:
      discard g.matches("digest", digestV, budget = 3)
    check g.judge("digest", digestV, budget = 3) == vRefused
    check g.judge("digest", digestV) == vAccepted
    check g.judge("digest", greeting) == vRejected

  test "payload length pins":
    var g = initGrammar()
    g.rule "k32", g.rec(sym"key", g.kindOf({bBytes}, len = 32))
    g.seal()
    check g.matches("k32", record(sym"key", bytes(seed32)))
    check not g.matches("k32", record(sym"key", bytes(seed32[0 ..< 31])))

  test "wide choices are balanced, not deep":
    # a 20k-symbol vocabulary once overflowed the seal walks; balanced
    # choice trees keep every walk logarithmic in width
    var g = initGrammar()
    var alts: seq[PatId]
    for i in 0 ..< 20_000:
      alts.add g.lit(sym("s" & $i))
    g.rule "vocab", g.choice(alts)
    g.seal(start = "vocab")
    check g.matches(sym"s19999")
    check not g.matches(sym"nope")

  test "construction refuses past the pattern depth cap":
    var g = initGrammar()
    let parts = newSeqWith(MaxPatternDepth + 76, g.kindOf({bNum}))
    expect GrammarError:
      discard g.group(parts)

  test "judgment nesting refuses instead of crashing":
    # a nullable chain per level times nested frames outruns any stack;
    # the answer is vRefused, and the grammar keeps answering after
    var g = initGrammar()
    var parts: seq[PatId]
    for _ in 0 ..< 300:
      parts.add g.opt(g.kindOf({bNum}))
    parts.add g.opt(g.refTo("r"))
    g.rule "r", g.frame(bList, g.group(parts))
    g.seal(start = "r")
    var v = list(@[])
    for _ in 0 ..< 4:
      v = list(@[v])
    check g.judge(v) == vRefused
    check g.judge(list(@[num"1"])) == vAccepted

  test "literals are mark-exact":
    var g = initGrammar()
    g.rule "t", g.rec(sym"t", g.lit(sym"a"))
    g.rule "m", g.rec(sym"t", g.any(mrMarked))
    g.seal()
    check g.matches("t", record(sym"t", sym"a"))
    check not g.matches("t", record(sym"t", mark(sym"a")))
    check g.matches("m", record(sym"t", mark(sym"a")))
    check not g.matches("m", record(sym"t", sym"a"))

suite "composition":
  test "rule names enumerate in canonical order":
    # the rule table is a dictionary, so definition order is canonical
    # key order — every implementation enumerates the same way
    var g = dialects()
    check g.ruleNames ==
      @[
        "big", "dec", "file", "start", "digest", "pinned", "signed", "fsentry",
        "keypair", "fileinfo", "directory", "signature",
      ]
    check g.readings(fileV, g.ruleNames).accepted == @["file", "fsentry"]

  test "a grammar is a value: snapshot, growth, reset":
    var g = dialects()
    let pristine = g
    let sealedSize = g.patCount
    for v in [fileV, nestedDirV, signedV, pinnedV]:
      discard g.matches("fsentry", v)
      discard g.judge("pinned", v)
    check g.patCount >= sealedSize
    check pristine.patCount == sealedSize # the snapshot did not move
    g = pristine
    check g.patCount == sealedSize # reset is assignment
    check g.matches("directory", nestedDirV)

  test "recognizer captures for wiring":
    let gr = new Grammar
    gr[] = dialects()
    let isFile = gr.recognizer("file")
    check isFile(fileV)
    check not isFile(digestV)
    # the shared automaton warms through the same ref
    discard isFile(nestedDirV)
    check gr[].patCount >= dialects().patCount

# ================ PROPERTIES ================

proc bytesOf(rng: var Rand, n: int): seq[byte] =
  newSeqWith(n, byte rng.rand(255))

proc feedOf(rng: var Rand, n: int): ByteFeed =
  initFeed(rng.bytesOf(n))

suite "properties":
  test "generated values are canonical":
    var rng = initRand(0xB100D)
    for i in 0 ..< 60:
      var f = rng.feedOf(48)
      let v = f.genValue(3)
      check decode(encode(v)) == v

  test "the engine agrees with the naive interpreter":
    # multi-rule spec grammars: refs, frame-guarded recursion, parity
    # and guardedness all in the oracle's path, not just hand tests
    var rng = initRand(0xB417)
    var ran = 0
    for i in 0 ..< 600:
      let outcome = agreeCase(rng.bytesOf(72))
      if outcome.isNone:
        continue # refused at seal or on budget
      let (want, got, again) = outcome.get
      check got == want
      check again == want # residual growth never changes a verdict
      inc ran
    check ran > 150

  test "the oracle cuts vacuous ref cycles":
    # the fuzzer's one real find, kept as a fixed case: r0 = (ref r1),
    # r1 = (cat (ref r0) never). The engine seals it because
    # never-annihilation prunes the cycle structurally, but the raw spec
    # still holds it — without nMatch's same-slice guard the oracle
    # recursed forever where the least fixpoint answers false
    let rs =
      @[
        Spec(kind: skRef, ix: 1),
        Spec(kind: skGroup, a: Spec(kind: skRef, ix: 0), b: Spec(kind: skNever)),
      ]
    let s = Spec(kind: skRef, ix: 0)
    check not nMatches(s, [sym"a"], rs)
    check not nMatches(s, [], rs)
    # and the engine agrees on the sealed shape
    var g = initGrammar()
    let refIds = @[g.refTo("r0"), g.refTo("r1")]
    g.rule "r0", g.build(rs[0], refIds)
    g.rule "r1", g.build(rs[1], refIds)
    g.rule "t", g.frame(bList, g.build(s, refIds))
    g.seal()
    check not g.matches("t", list(sym"a"))
    check not g.matches("t", list())

  test "choice only widens":
    var rng = initRand(0xC401CE)
    var implied = 0
    for i in 0 ..< 300:
      var f = rng.feedOf(40)
      let s = f.genSpec(2)
      let q = f.genSpec(2)
      var g = initGrammar()
      let ps = g.build(s)
      g.rule "s", g.frame(bList, ps)
      g.rule "sq", g.frame(bList, g.choice(ps, g.build(q)))
      try:
        g.seal()
      except GrammarError:
        continue
      var vs: seq[Value]
      for _ in 0 ..< int(f.next mod 5):
        vs.add f.genValue(2)
      let lv = list(vs)
      if g.matches("s", lv):
        check g.matches("sq", lv)
        inc implied
    check implied > 20

  test "open dictionaries stay open under insertion":
    var rng = initRand(0x0D1C7)
    var ran = 0
    for i in 0 ..< 300:
      var f = rng.feedOf(48)
      let es = f.genEntries(1)
      if es.len == 0:
        continue
      var g = initGrammar()
      var required: seq[(Value, PatId)]
      let mask = f.next
      for j, e in es:
        if ((int(mask) shr (j and 7)) and 1) == 1:
          required.add (e[0], g.lit(e[1]))
      g.rule "open", g.openDict(required)
      var all: seq[(Value, PatId)]
      for e in es:
        all.add (e[0], g.lit(e[1]))
      g.rule "closed", g.dictOf(all)
      g.seal()
      let d = dict(es)
      check g.matches("open", d)
      check g.matches("closed", d)
      let freshKey = sym("fresh" & $i)
      var collides = false
      for e in es:
        if e[0] == freshKey:
          collides = true
      if collides:
        continue
      var es2 = es
      es2.add (freshKey, f.genValue(1))
      let d2 = dict(es2)
      check g.matches("open", d2)
      check not g.matches("closed", d2)
      inc ran
    check ran > 100

# ================ THE GRAMMAR DIALECT ================

proc opv(name: string, ops: varargs[Value]): Value =
  record(@[sym(name)] & @ops, marked = true)

proc refv(name: string): Value =
  sym(name, marked = true)

proc gram(rules: seq[(Value, Value)]): Value =
  mark record(sym"grammar", dict(rules))

suite "the grammar dialect":
  test "the dialect describes itself":
    var meta = load(grammarGrammar())
    check meta.matches(grammarGrammar())
    check meta.matches(spelledDialect)
    check not meta.matches(digestV)
    # the inert spelling is data about a grammar, not the dialect
    check not meta.matches(unmark(grammarGrammar()))

  test "the self-description admits what sealing then refuses":
    # the description speaks for the spelling; sealing laws stay
    # judgments, so shape-valid tables can still refuse to load
    let cyclic = gram @[(sym"a", refv"b"), (sym"b", refv"a")]
    var meta = load(grammarGrammar())
    check meta.matches(cyclic)
    expect GrammarError:
      discard load(cyclic)

  test "loading refuses spellings outside the dialect":
    let bad = [
      record(sym"grammar", dict(@[(sym"a", opv"num")])), # inert top
      mark record(sym"grammar"), # no rule table
      mark record(sym"grammatik", dict(@[])), # wrong head
      gram @[(sym"a", opv("kind", sym"sym"))], # the old sketch spelling
      gram @[(sym"a", refv"ghost")], # dangling reference
      gram @[(sym"a", num("5", marked = true))], # marked atom
      gram @[(sym"a", opv"lit")], # lit wants one value
      gram @[(sym"a", opv("bytes", num"-3"))], # negative length
      gram @[(sym"a", opv("bytes", text"x"))], # length is a number
      gram @[(sym"a", opv("open", opv"any"))], # open wants a template
      gram @[(sym"a", opv("open", dict(@[(sym"k", opv("?", opv"num"))])))],
        # optional entry in an open dictionary
      gram @[(sym"a", opv("open", values.set(opv("*", opv"num"))))],
        # star run in an open set
      gram @[(sym"a", opv("marked", opv("cat", opv"num")))], # demand on a sequence
      gram @[(sym"a", dict(@[(opv"sym", opv"num")]))], # pattern key
      gram @[(sym"a", values.set(opv("?", opv"num")))], # opt among members
      gram @[(mark sym"a", opv"num")], # marked rule name
    ]
    for v in bad:
      expect GrammarError:
        discard load(v)

  test "inert records are templates whatever their heads spell":
    # the mark is the reading: an inert (? 1) in value position is a
    # record template, never the optional-entry operator
    var g = readGrammar"{d: {k: (? 1)}}"
    check g.matches("d", dict(@[(sym"k", record(sym"?", num"1"))]))
    check not g.matches("d", dict(@[(sym"k", num"1")]))
    check not g.matches("d", dict(@[]))
    var meta = load(grammarGrammar())
    check meta.matches(readValue"!(grammar {d: {k: (? 1)}})")
    # an inert (lit …) key is a template, not a literal escape; load
    # and the self-description refuse the same spelling
    expect GrammarError:
      discard readGrammar"{d: {(lit go!): !(num)}}"
    check not meta.matches(readValue"!(grammar {d: {(lit go!): !(num)}})")
    # an inert (* …) set member is neither a literal nor a run
    expect GrammarError:
      discard readGrammar"{s: {(* !(num))}}"
    check not meta.matches(readValue"!(grammar {s: {(* !(num))}})")

  test "a startless table loads and refuses the no-name question":
    var g = readGrammar"{a: !(num)}"
    check g.matches("a", num"1")
    check g.judge("a", num"1") == vAccepted
    expect GrammarError:
      discard g.matches(num"1")
    expect GrammarError:
      discard g.judge(num"1")

  test "mark lanes share a shape through a sequence rule":
    # a demand cannot ride a reference — the rule owns its meaning
    # everywhere it is referenced — so the two polarities of one shape
    # factor through a sequence rule and frame operators over it
    var g = readGrammar"""{
      greetbody: !(cat greet !(text))
      inertgreet: !(record greetbody!)
      markedgreet: !(marked !(record greetbody!))
    }"""
    let v = record(sym"greet", text"hi")
    check g.matches("inertgreet", v)
    check not g.matches("inertgreet", mark(v))
    check g.matches("markedgreet", mark(v))
    check not g.matches("markedgreet", v)
    expect GrammarError: # and through a bare reference it stays refused
      discard readGrammar"{a: !(num) b: !(marked a!)}"

  test "parity settles per pattern, not per unfolding":
    # p = star(group(p, p)) doubles the unfolded tree each level while
    # the pool stays tiny; sealing must cost the pool, not the tree
    var g = initGrammar()
    var p = g.entry(g.any(mrAny), g.any(mrAny))
    for _ in 0 ..< 64:
      p = g.star(g.group(p, p))
    g.rule "d", g.frame(bDict, p)
    g.seal(start = "d")
    check g.matches(dict(@[]))
    # judging the pathological shape against content is the budget's
    # problem, and refusal is its answer
    check g.judge(dict(@[(sym"a", num"1")])) == vRefused

  test "readGrammar wraps a bare rule table":
    var g = readGrammar"{start: (point !(num) !(num))}"
    check g.matches(record(sym"point", num"1", num"2"))
    check not g.matches(record(sym"point", num"1", text"x"))
    expect GrammarError: # anything but a dictionary refuses
      discard readGrammar"[1 2 3]"

  test "whatever loads is self-described":
    var meta = load(grammarGrammar())
    var rng = initRand(20260724)
    var loadedCount = 0
    for _ in 0 ..< 400:
      var f = rng.feedOf(48)
      let gv = f.genGrammarValue()
      var lg: Grammar
      var ok = false
      try:
        lg = load(gv)
        ok = true
      except GrammarError:
        discard
      if ok:
        inc loadedCount
        check meta.matches(gv)
        # and the loaded grammar judges strangers without crashing
        var f2 = rng.feedOf(32)
        check lg.judge(f2.genValue(2), budget = 100_000) in
          {vAccepted, vRejected, vRefused}
    check loadedCount > 30 # the generator mostly speaks the dialect
