import std/[unittest, random, sequtils]
import pkg/core
import lib/[grammar, read]
import ./gen

# ================ THE SHAPES THESE SUITES USE ================

const spelled = """{
  start: !(or point! tag!)
  point: (point !(num) !(num))
  tag: (tag !(sym))
  digest: (digest !(sym) !(bytes 32))
  info: {name: !(? !(text)) algo: !(sym)}
  tree: !(or !(list !(* tree!)) !(num))
  members: {a b !(* !(sym))}
  opened: !(open (point !(num) !(num)))
  lanes: !(marked !(record greet !(text)))
}"""

proc shapes(): Grammar =
  readGrammar(spelled)

const blShapeText = staticRead("../grammars/bl.bl")

proc blShapes(): Grammar =
  ## what bl's own verbs say, as shipped
  readGrammar(blShapeText)

let
  pointV = record(sym"point", num"1", num"2")
  tagV = record(sym"tag", sym"north")
  digestV = record(sym"digest", sym"sha256", bytes(newSeqWith(32, byte 7)))

proc bytesOf(rng: var Rand, n: int): seq[byte] =
  newSeqWith(n, byte rng.rand(255))

proc feedOf(rng: var Rand, n: int): ByteFeed =
  initFeed(rng.bytesOf(n))

# ================ READINGS ================

suite "readings":
  test "every rule that speaks is named":
    var g = shapes()
    let r = g.readings(pointV, g.ruleNames)
    # in the rule table's own canonical key order
    check r.accepted == @["point", "start", "opened"]
    check r.refused.len == 0

  test "refusal is its own answer, not rejection":
    var g = shapes()
    let full = g.readings(pointV, g.ruleNames)
    let tiny = g.readings(pointV, g.ruleNames, budget = 3)
    check full.accepted.len > 0
    check tiny.accepted.len == 0
    for n in full.accepted:
      check n in tiny.refused

  test "an unnamed value reads as nothing":
    var g = shapes()
    check g.readings(text"noise", g.ruleNames).accepted.len == 0

# ================ UNPARSING ================

suite "unparsing":
  test "the operator form reloads and judges the same":
    var g = shapes()
    var h = load(g.unparse())
    check h.ruleNames == g.ruleNames
    for v in [
      pointV,
      tagV,
      digestV,
      text"noise",
      list(list(), num"1"),
      dict(@[(sym"algo", sym"sha256")]),
      values.set(sym"a", sym"b"),
      mark(record(sym"greet", text"hi")),
      record(sym"point", num"1", num"2", num"3"),
    ]:
      check g.readings(v, g.ruleNames).accepted == h.readings(v, h.ruleNames).accepted

  test "the dialect's own description survives the trip":
    var meta = load(grammarGrammar())
    var back = load(meta.unparse())
    for v in [grammarGrammar(), readValue(spelled), digestV, mark(sym"x")]:
      check meta.judge(v) == back.judge(v)

  test "identity is of the definition, so the spelling is not the name":
    var g = shapes()
    # same language, different definition: unparsing is for reading
    check g.unparse() != readValue("!(grammar " & spelled & ")")

  test "empty and never have spellings":
    var g = initGrammar()
    g.rule "nothing", g.never()
    g.rule "silence", g.empty()
    g.seal()
    check g.unparse(g.rulePattern("nothing")) == readValue"!(or)"
    check g.unparse(g.rulePattern("silence")) == readValue"!(cat)"
    var h = load(g.unparse())
    check h.isEmpty("nothing")
    check not h.isEmpty("silence")

  test "an unsatisfiable length is spelled as written, not as its language":
    # the point of a lint message is to show what was written
    var g = initGrammar()
    g.rule "dead", g.kindOf({bNum}, len = 0)
    g.seal()
    check g.unparse(g.rulePattern("dead")) == readValue"!(num 0)"
    check load(g.unparse()).isEmpty("dead")

  test "a frame kind a length excluded is not widened back":
    var g = initGrammar()
    g.rule "dead", g.kindOf({bList}, len = 3)
    g.seal()
    var h = load(g.unparse())
    check h.isEmpty("dead")
    check not h.matches("dead", list())

  test "an inert frame literal comes back as a template, and means the same":
    # the dialect's own rule: where both readings coincide, writing out
    # picks the shorter one, so it settles on the second round
    var g = readGrammar"{start: !(lit {})}"
    let once = g.unparse()
    var h = load(once)
    check once == readValue"!(grammar {start: {}})"
    check h.unparse() == readValue"!(grammar {start: !(set !(cat))})"
    check load(h.unparse()).unparse() == h.unparse()
    for v in [values.set(newSeq[Value]()), values.set(sym"a"), list()]:
      check g.matches(v) == h.matches(v)

  test "writing out settles, and never moves a judgment":
    var rng = initRand(0x57AB)
    var checked = 0
    for _ in 0 ..< 200:
      var f = rng.feedOf(48)
      var g: Grammar
      try:
        g = load(f.genGrammarValue())
      except GrammarError:
        continue
      var once = load(g.unparse())
      var twice = load(once.unparse())
      check once.unparse() == twice.unparse() # a fixpoint by the second
      for _ in 0 ..< 3:
        var vf = rng.feedOf(20)
        let v = vf.genValue(2)
        for name in g.ruleNames:
          let a = g.judge(name, v, budget = 100_000)
          let b = twice.judge(name, v, budget = 100_000)
          if a != vRefused and b != vRefused:
            check a == b
            inc checked
    check checked > 300

  test "an empty children pattern is not a bare kind operator":
    var g = initGrammar()
    g.rule "empties", g.frame(bList, g.empty())
    g.seal()
    var h = load(g.unparse())
    check h.matches("empties", list())
    check not h.matches("empties", list(num"1"))

# ================ EXPECTATION AND EXPLANATION ================

suite "explanation":
  test "a miss is exactly where every reading died":
    var g = shapes()
    let m = g.explain("point", record(sym"point", num"1", text"x"))
    check m.isSome
    check m.get.path == @[2]
    check m.get.found.get == text"x"
    check m.get.expected == @[readValue"!(num)"]
    check not m.get.complete

  test "running out is a miss with nothing found":
    var g = shapes()
    let m = g.explain("point", record(sym"point", num"1"))
    check m.isSome
    check m.get.found.isNone
    check m.get.expected == @[readValue"!(num)"]

  test "blame descends only when one frame could have been meant":
    var g = shapes()
    # `start` is a choice of two records; a record with a third head
    # matches neither, so blame stays on the value itself
    let m = g.explain(record(sym"nope", num"1"))
    check m.isSome
    check m.get.path.len == 0
    check m.get.expected.len == 2
    # with the shape named, blame walks into it
    let inner = g.explain("point", record(sym"point", num"1", text"x"))
    check inner.get.path == @[2]

  test "a nested miss carries the whole path":
    var g =
      readGrammar"""{
      start: (outer (inner !(num) !(sym)))
    }"""
    let m = g.explain(record(sym"outer", record(sym"inner", num"1", num"2")))
    check m.isSome
    check m.get.path == @[1, 2]
    check m.get.found.get == num"2"
    check m.get.expected == @[readValue"!(sym)"]

  test "a shape that could have ended says so":
    var g = shapes()
    let m = g.explain("tree", list(list(), text"no"))
    check m.isSome
    check m.get.complete
    check m.get.expected.len == 2

  test "accepting leaves nothing to explain":
    var g = shapes()
    for v in [pointV, tagV]:
      check g.explain(v).isNone
      check g.explain("start", v).isNone

  test "nothing the miss expected admits what it found":
    # the strong claim: firsts and unparse agree with the matcher
    var g = shapes()
    for (rule, v) in [
      ("point", record(sym"point", num"1", text"x")),
      ("digest", record(sym"digest", text"sha256", bytes(newSeq[byte](32)))),
      ("digest", record(sym"digest", sym"sha256", bytes(newSeq[byte](31)))),
      ("info", dict(@[(sym"algo", num"1")])),
      ("tree", list(list(), text"no")),
      ("members", values.set(sym"a", num"1")),
    ]:
      let m = g.explain(rule, v)
      check m.isSome
      check m.get.more == 0
      check m.get.found.isSome
      # rebuild the expectations as rules of the same grammar, so any
      # references inside them still resolve, then ask each one
      var table = g.unparse().tail[0].entries.toSeq
      for i, e in m.get.expected:
        table.add (sym("expectation-" & $i), e)
      var probe = load(mark record(sym"grammar", dict(table)))
      for i in 0 ..< m.get.expected.len:
        check not probe.matches("expectation-" & $i, m.get.found.get)

  test "a miss is a value like anything else":
    var g = shapes()
    var described = blShapes()
    for (rule, v) in [
      ("point", record(sym"point", num"1", text"x")), # found something
      ("point", record(sym"point", num"1")), # ran out
      ("tree", list(list(), text"no")), # could have ended
    ]:
      let m = g.explain(rule, v).get.toValue
      check m.head == sym"miss"
      check described.matches("miss", m)

  test "the capped form is described too":
    var g = initGrammar()
    var alts: seq[PatId]
    for i in 0 ..< 40:
      alts.add g.lit(sym("s" & $i))
    g.rule "vocab", g.choice(alts)
    g.seal(start = "vocab")
    var described = blShapes()
    check described.matches("miss", g.explain(num"1", cap = 5).get.toValue)

  test "expectations are capped, and say so":
    var g = initGrammar()
    var alts: seq[PatId]
    for i in 0 ..< 40:
      alts.add g.lit(sym("s" & $i))
    g.rule "vocab", g.choice(alts)
    g.seal(start = "vocab")
    let m = g.explain(num"1", cap = 5)
    check m.isSome
    check m.get.expected.len == 5
    check m.get.more == 35

  test "firsts stops at a frame":
    var g = shapes()
    let heads = g.firsts(g.rulePattern("start"))
    check heads.len == 2 # two records, not what is inside them

# ================ EMPTINESS ================

suite "emptiness":
  test "a length nothing satisfies is a language nothing satisfies":
    var g =
      readGrammar"""{
      zero: !(num 0)
      one: !(num 1)
      nil-with-payload: !(text 0)
    }"""
    check g.isEmpty("zero")
    check not g.isEmpty("one")
    check not g.isEmpty("nil-with-payload")
    check g.emptyRules() == @["zero"]

  test "a record needs a head, so an empty children pattern describes nothing":
    var g = initGrammar()
    g.rule "headless", g.frame(bRecord, g.empty())
    g.rule "list", g.frame(bList, g.empty())
    g.seal()
    check g.isEmpty("headless")
    check not g.isEmpty("list")

  test "emptiness travels through references and frames":
    var g =
      readGrammar"""{
      a: !(list b!)
      b: !(cat !(num 0) !(num))
      c: !(or b! !(num))
    }"""
    check g.isEmpty("a")
    check g.isEmpty("b")
    check not g.isEmpty("c")

  test "lint names the rule and shows what was written":
    var g =
      readGrammar"""{
      start: !(or !(num) !(num 0))
      dead: !(num 0)
    }"""
    let found = g.lint()
    check found.len == 2
    check found[0].rule == "dead"
    check found[0].reason == "describes no value"
    check found[1].rule == "start"
    check found[1].pattern == readValue"!(num 0)"

  test "a healthy grammar lints clean":
    var g = shapes()
    check g.lint().len == 0
    check g.emptyRules().len == 0
    var meta = load(grammarGrammar())
    check meta.lint().len == 0

# ================ CONSTRUCTION ================

suite "construction":
  test "the smallest value of each shape":
    var g = shapes()
    check g.witness("point").get == record(sym"point", num"0", num"0")
    check g.witness("tag").get == record(sym"tag", sym"a")
    check g.witness("tree").get == num"0"
    check g.witness("members").get == values.set(sym"a", sym"b")
    check g.witness("info").get == dict(@[(sym"algo", sym"a")])
    check g.witness("lanes").get == mark(record(sym"greet", text""))
    check g.witness("digest").get == record(
      sym"digest", sym"a", bytes(newSeq[byte](32))
    )

  test "what a grammar builds, it admits":
    var g = shapes()
    var rng = initRand(0x9E3)
    for name in g.ruleNames:
      for size in [0, 3, 8, 20]:
        for _ in 0 .. 25:
          let v = g.generate(name, rng, size)
          check v.isSome
          check g.matches(name, v.get)
          check decode(encode(v.get)) == v.get

  test "an empty rule builds nothing":
    var g = readGrammar"{start: !(num 0)}"
    var rng = initRand(1)
    check g.witness("start").isNone
    check g.generate("start", rng, 9).isNone

  test "a rule that describes a sequence describes no single value":
    var g = readGrammar"{start: !(cat !(num) !(num))}"
    check g.witness("start").isNone

  test "the smallest value is the same value every time":
    var g = shapes()
    for _ in 0 .. 3:
      check g.witness("tree") == g.witness("tree")

  test "keyed frames keep canonical order, or refuse to build":
    # unknown runs in a dictionary or set would land wherever canonical
    # order puts them, which is not where the pattern spelled them
    var g =
      readGrammar"""{
      opendict: !(open {algo: !(sym)})
      openset: !(open {a b})
      quantified: !(dict !(* !(sym) !(num)))
    }"""
    var rng = initRand(4)
    for name in ["opendict", "openset", "quantified"]:
      for size in [0, 6, 15]:
        for _ in 0 .. 10:
          let v = g.generate(name, rng, size)
          check v.isSome
          check g.matches(name, v.get)
          check decode(encode(v.get)) == v.get

  test "recursion through frames terminates":
    var g = readGrammar"{start: !(or !(list !(* start!)) !(num))}"
    var rng = initRand(11)
    for size in [0, 5, 25, 60]:
      for _ in 0 .. 20:
        let v = g.generate("start", rng, size)
        check v.isSome
        check g.matches(v.get)

# ================ PROPERTIES ================

suite "properties over generated grammars":
  test "what a generated grammar builds, it admits":
    var rng = initRand(0xB1D)
    var built = 0
    for i in 0 ..< 400:
      var f = rng.feedOf(48)
      let gv = f.genGrammarValue()
      var g: Grammar
      try:
        g = load(gv)
      except GrammarError:
        continue
      let pr = g.productivity
      for name in g.ruleNames:
        let p = g.rulePattern(name)
        for size in [0, 5, 12]:
          let v = g.generate(pr, p, rng, size)
          if v.isNone:
            continue
          inc built
          check decode(encode(v.get)) == v.get
          # refusal is an answer; rejecting what it built is not
          check g.judge(name, v.get, budget = 200_000) != vRejected
    check built > 200

  test "unparsing a generated grammar keeps its judgments":
    var rng = initRand(0x5E11)
    var compared = 0
    for i in 0 ..< 300:
      var f = rng.feedOf(48)
      var g: Grammar
      try:
        g = load(f.genGrammarValue())
      except GrammarError:
        continue
      var h: Grammar
      h = load(g.unparse()) # must never refuse: same laws, same shape
      check h.ruleNames == g.ruleNames
      for _ in 0 ..< 4:
        var vf = rng.feedOf(24)
        let v = vf.genValue(2)
        for name in g.ruleNames:
          let a = g.judge(name, v, budget = 100_000)
          let b = h.judge(name, v, budget = 100_000)
          if a == vRefused or b == vRefused:
            continue
          check a == b
          inc compared
    check compared > 500

  test "explanation answers exactly when judgment rejects":
    var rng = initRand(0xE7)
    var explained = 0
    for i in 0 ..< 300:
      var f = rng.feedOf(48)
      var g: Grammar
      try:
        g = load(f.genGrammarValue())
      except GrammarError:
        continue
      for _ in 0 ..< 3:
        var vf = rng.feedOf(24)
        let v = vf.genValue(2)
        for name in g.ruleNames:
          let verdict = g.judge(name, v, budget = 100_000)
          if verdict == vRefused:
            continue
          let m =
            try:
              g.explain(name, v, budget = 100_000)
            except BudgetError:
              continue
          check m.isNone == (verdict == vAccepted)
          inc explained
    check explained > 500

  test "emptiness and construction agree on the shapes":
    var g = shapes()
    for name in g.ruleNames:
      check g.isEmpty(name) == g.witness(name).isNone

# ================ REFUTING AN INCLUSION ================

suite "counterexamples":
  test "a wider shape produces what a narrower one refuses":
    var wide = readGrammar"{start: !(or (point !(num) !(num)) (tag !(sym)))}"
    var narrow = readGrammar"{start: (point !(num) !(num))}"
    var rng = initRand(3)
    let found = wide.counterexamples("start", narrow, "start", rng, tries = 40)
    check found.len > 0
    for v in found:
      check wide.matches(v) # only what the first admits may speak
      check not narrow.matches(v)

  test "a narrower shape produces nothing against a wider one":
    var wide = readGrammar"{start: !(or (point !(num) !(num)) (tag !(sym)))}"
    var narrow = readGrammar"{start: (point !(num) !(num))}"
    var rng = initRand(3)
    check narrow.counterexamples("start", wide, "start", rng, tries = 60).len == 0

  test "openness only ever widens":
    var closed = readGrammar"{start: (point !(num) !(num))}"
    var opened = readGrammar"{start: !(open (point !(num) !(num)))}"
    var rng = initRand(8)
    check closed.counterexamples("start", opened, "start", rng, tries = 60).len == 0
    check opened.counterexamples("start", closed, "start", rng, tries = 60).len > 0

  test "the dialect builds grammars its own description admits":
    # the loop closing: the grammar of grammars generates grammars, and
    # every one of them is described by what built it. Loading is a
    # further judgment — the description speaks for the spelling, and
    # sealing's laws stay laws — so some well-spelled tables still
    # refuse, which is the one-directional honesty law with data behind
    # it rather than a hand-written case
    var meta = load(grammarGrammar())
    var rng = initRand(0x5E1F)
    var built, loaded, refused = 0
    for size in [0, 8, 20, 40]:
      for _ in 0 ..< 30:
        let v = meta.generate("start", rng, size)
        check v.isSome
        inc built
        check meta.matches(v.get) # described by what built it
        try:
          discard load(v.get)
          inc loaded
        except GrammarError:
          inc refused
    check built == 120
    check loaded > 20 # the tower stands
    check refused > 0 # and spelling is not sealing

  test "silence is not a proof":
    # two disjoint shapes, but the first builds nothing, so nothing speaks
    var nothing = readGrammar"{start: !(num 0)}"
    var other = readGrammar"{start: !(text)}"
    var rng = initRand(1)
    check nothing.counterexamples("start", other, "start", rng, tries = 20).len == 0

# ================ WHAT BL'S OWN VERBS SAY ================

suite "the shipped shapes":
  test "grammars/bl.bl loads, lints clean, and describes itself to us":
    var described = blShapes()
    check described.lint().len == 0
    check described.emptyRules().len == 0
    # a startless table is the ordinary router shape
    expect GrammarError:
      discard described.matches(num"1")

  test "every shape it names can be built and read back":
    var described = blShapes()
    var rng = initRand(21)
    for name in described.ruleNames:
      for size in [0, 4, 10]:
        let v = described.generate(name, rng, size)
        check v.isSome
        check described.matches(name, v.get)
