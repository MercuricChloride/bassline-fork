import std/strutils
import ../core
import ../lib/[digest, infer]
import ./[gsource, store, util]

const help = """
bl grammar <what> [options] <grammar> [...]

  self                    the dialect described in itself. It is a
                          grammar like any other: it admits itself, and
                          it builds grammars
  rules <grammar>         the names it defines, in canonical order
  show <grammar>          write the grammar back out, operator by
                          operator. The spelling is a different
                          definition and so a different name; this is
                          for reading, never for identity
  digest <grammar>        the name of the grammar as written
  lint <grammar>          rules and alternatives that describe nothing
  diff <a> <b>            values a admits that b does not, by sampling
  vectors <grammar>       the grammar, then one (vector ...) per rule
                          per built value, with the verdict it froze
  infer                   read values on stdin and write a dialect that
                          describes them. Soundness is checked, never
                          assumed: it says how many of its own corpus
                          the answer admits, and refuses to call an
                          inference that misses any of them a success

Options:
  --rule:NAME    the rule to speak for (default `start`)
  --other:NAME   diff: the rule on the second grammar (default --rule)
  -n:COUNT       how many values to try (default 100, vectors 8)
  --seed:N       repeat a particular run; without one, a run is picked
                 and its seed written to stderr
  --size:K       how much structure to spend per value (default 6)
  --store:PATH   where names resolve

  infer only:
  --enum:N       most distinct values a slot may hold and still read as
                 vocabulary rather than as a kind (default 16)
  --repeat:N     how many times over those values must have been seen
                 before they count as vocabulary (default 2)
  --positional:N longest fixed-length list still spelled position by
                 position rather than quantified (default 8)
  --map-ratio:N  distinct keys per key-per-dictionary before a
                 dictionary reads as a map rather than a shape (default 3)
  --holdout:P    infer from the first 100-P percent and report what
                 share of the rest the answer admits: generalisation,
                 measured rather than claimed

Everything here writes values; pipe them through bl cat to read them.
lint exits 1 when it finds something. diff exits 1 when it finds a
counterexample, and finding none is not a proof: sampling can only
refute.
"""

proc runSelf() =
  emit grammarGrammar()

proc runRules(spec, root: string) =
  for name in grammarFrom(spec, root).ruleNames:
    emit sym(name)

proc runShow(spec, root: string) =
  emit grammarFrom(spec, root).unparse()

proc runDigest(spec, root: string) =
  emit toValue digest grammarValue(spec, root)

proc runLint(spec, root: string) =
  let findings = grammarFrom(spec, root).lint()
  for f in findings:
    emit record(sym"finding", sym(f.rule), text(f.reason), f.pattern)
  if findings.len > 0:
    quit 1

proc runDiff(
    specA, specB, root, ruleA, ruleB: string, count, seed, size: int, seeded: bool
) =
  var a = grammarFrom(specA, root)
  var b = grammarFrom(specB, root)
  let fromRule = a.startingRule(ruleA)
  let againstRule = b.startingRule(if ruleB != "": ruleB else: ruleA)
  if a.isEmpty(fromRule):
    quit "'" & fromRule & "' describes no value, so it is inside anything"
  if a.witness(fromRule).isNone:
    # productive but not buildable: a rule describing a sequence rather
    # than a value, or one canonical order will not let us arrange.
    # Saying nothing here would read as saying no
    stderr.writeLine "-- nothing could be built for '" & fromRule &
      "', so this sample says nothing either way"
    quit 2
  var rng = seededRand(seed, seeded)
  let found = a.counterexamples(fromRule, b, againstRule, rng, count, size)
  for v in found:
    emit record(sym"counterexample", v)
  if found.len > 0:
    quit 1

proc runVectors(spec, root: string, count, seed, size: int, seeded: bool) =
  ## the conformance triples: a grammar, and the verdicts it freezes for
  ## values it built itself. Values built for one rule are near misses
  ## for the others, which is where a corpus earns its keep. Refusal is
  ## never a vector: the budget is local and no verdict may rest on it
  let source = grammarValue(spec, root)
  var g = load(source)
  let name = toValue digest source
  emit source
  var rng = seededRand(seed, seeded)
  let pr = g.productivity
  var built: seq[Value]
  for rule in g.ruleNames:
    for i in 0 ..< count:
      let v = g.generate(pr, g.rulePattern(rule), rng, if i == 0: 0 else: size)
      if v.isSome and v.get notin built:
        built.add v.get
  for v in built:
    for rule in g.ruleNames:
      let verdict = g.judge(rule, v, budget = 8 * DefaultBudget)
      if verdict == vRefused:
        continue
      emit record(
        sym"vector",
        name,
        sym(rule),
        v,
        sym(if verdict == vAccepted: "accepted" else: "rejected"),
      )

proc runInfer(cfg: Settings, holdout: int) =
  var corpus: seq[Value]
  eachValue(
    stdin,
    proc(v: Value) =
      corpus.add v
    ,
  )
  if corpus.len == 0:
    quit "nothing to infer from"
  let cut =
    if holdout <= 0:
      corpus.len
    else:
      max(1, corpus.len - corpus.len * holdout div 100)
  let learn = corpus[0 ..< cut]
  let shape = infer(learn, cfg)
  emit shape
  let held = conforms(shape, learn)
  stderr.writeLine "-- " & $learn.len & " values in, " & $held &
    " admitted by what came out"
  if cut < corpus.len:
    let rest = corpus[cut ..< corpus.len]
    let recall = conforms(shape, rest)
    stderr.writeLine "-- held back " & $rest.len & ", of which " & $recall &
      " are admitted (" & $(recall * 100 div rest.len) & "%)"
  if held < learn.len:
    stderr.writeLine "-- an inference that misses its own corpus is a defect"
    quit 1

proc run*(args: seq[string]) =
  var
    what = ""
    specs: seq[string]
    ruleA = ""
    ruleB = ""
    count = -1
    seed = 0
    seeded = false
    size = 6
    root = defaultStoreRoot()
    cfg = defaults()
    holdout = 0
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "rule":
        ruleA = val
      of "other":
        ruleB = val
      of "n", "count":
        try:
          count = parseInt(val)
        except ValueError:
          quit "-n wants a number, got: " & val
      of "seed":
        try:
          seed = parseInt(val)
        except ValueError:
          quit "--seed wants a number, got: " & val
        seeded = true
      of "size":
        try:
          size = parseInt(val)
        except ValueError:
          quit "--size wants a number, got: " & val
      of "store":
        if val == "":
          quit "--store needs a path"
        root = val
      of "enum":
        cfg.enumMax = parseInt(val)
      of "repeat":
        cfg.enumRepeat = parseInt(val)
      of "positional":
        cfg.positionalMax = parseInt(val)
      of "map-ratio":
        cfg.mapRatio = parseInt(val)
      of "holdout":
        holdout = parseInt(val)
        if holdout < 1 or holdout > 90:
          quit "--holdout wants a percentage between 1 and 90"
      else:
        quit "unknown grammar option: " & key & "\n\n" & help
    else:
      if what == "":
        what = key
      else:
        specs.add key

  case what
  of "":
    echo help
  of "infer":
    if specs.len != 0:
      quit "bl grammar infer reads values on stdin\n\n" & help
    runInfer(cfg, holdout)
  of "self":
    if specs.len != 0:
      quit "bl grammar self takes no grammar; it is one\n\n" & help
    runSelf()
  of "rules":
    if specs.len != 1:
      quit "bl grammar rules takes one grammar\n\n" & help
    runRules(specs[0], root)
  of "show", "digest", "lint", "vectors":
    if specs.len != 1:
      quit "bl grammar " & what & " takes one grammar\n\n" & help
    case what
    of "show":
      runShow(specs[0], root)
    of "digest":
      runDigest(specs[0], root)
    of "lint":
      runLint(specs[0], root)
    else:
      runVectors(specs[0], root, (if count < 0: 8 else: count), seed, size, seeded)
  of "diff":
    if specs.len != 2:
      quit "bl grammar diff takes two grammars\n\n" & help
    runDiff(
      specs[0],
      specs[1],
      root,
      ruleA,
      ruleB,
      (if count < 0: 100 else: count),
      seed,
      size,
      seeded,
    )
  else:
    quit "bl grammar has no '" & what & "'\n\n" & help
