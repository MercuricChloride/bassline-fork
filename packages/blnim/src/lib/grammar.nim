{.experimental: "strictFuncs".}

## grammar: recognition of values by tree grammars.
##
## A grammar is a pool of interned patterns plus named rules. Patterns
## describe sequences of values; a pattern that admits exactly one value
## is a sequence pattern that consumes one. Judging a value derives the
## residual of a rule's pattern after consuming it and asks whether that
## residual admits the empty sequence.
##
##   var g = initGrammar()
##   g.rule "digest", g.rec(sym"digest", g.kindOf({bSym}), g.kindOf({bBytes}))
##   g.seal(start = "digest")
##   g.matches(record(sym"digest", sym"sha256", bytes(h)))   -> true
##
## Openness is pattern data: `openRec` trails a rest; `openDict`
## interleaves unknown entries at every gap, because unknown keys sort
## among the known ones. Every value-admitting pattern carries a mark
## demand (inert by default); matching carries no ambient state.
##
## Sealing checks the grammar: all rules defined, rule nullability, the
## recursion law (a rule may reach itself only through a frame, so the
## language of any sibling sequence stays regular), and the dictionary
## parity law (patterns in dictionary position admit an even count of
## values on every path). Sealing is a phase boundary: defining a rule
## or minting a reference afterwards is a defect.
##
## Judging carries a step budget; `matches` raises `BudgetError` when it
## is spent, `judge` answers `vRefused`. Residuals built while judging
## are interned into the pool, so a sealed grammar optimizes itself as
## it is used; verdicts never depend on that growth, and the recursion
## law keeps the reachable residuals finite.
##
## A Grammar is a value: copying it snapshots the learned pool and
## assigning a copy back is reset; `patCount` reads growth, which is how
## a holder of stranger grammars bounds space. Every judgment writes the
## pool, so a grammar-backed predicate is never `{.noSideEffect.}` and a
## shared grammar wants one thread. The stack is bounded on both sides:
## pattern nesting refuses at `MaxPatternDepth` when built (choices
## chain balanced, so wide vocabularies stay shallow), and judgment
## nesting refuses at `MaxJudgeDepth`, so a hostile grammar refuses
## instead of exhausting the stack. Value depth is the decoder's
## boundary, as before.

import std/[algorithm, random, sequtils, strutils, tables]
import ../core
import ./[hash, read]

type
  PatId* = int32
  RuleId* = int32

  MarkReq* = enum
    mrInert
    mrMarked
    mrAny

  PatKind = enum
    pEmpty
    pNotAllowed
    pChoice
    pGroup
    pStar
    pKind
    pLit
    pFrame
    pRef

  Pattern = object
    case kind: PatKind
    of pEmpty, pNotAllowed:
      discard
    of pChoice, pGroup:
      left, right: PatId
    of pStar:
      body: PatId
    of pKind:
      kinds: set[BlKind]
      req: MarkReq
      len: int
    of pLit:
      lit: Value
    of pFrame:
      frameKind: BlKind
      frameReq: MarkReq
      children: PatId
    of pRef:
      rule: RuleId

  Verdict* = enum
    vAccepted
    vRejected
    vRefused

  GrammarError* = object of CatchableError ## a malformed grammar, reported at seal

  BudgetError* = object of CatchableError
    ## the judgment budget was spent before an answer

  Grammar* = object
    pats: seq[Pattern]
    ids: Table[Pattern, PatId]
    nul: seq[bool] # per pattern: admits the empty sequence
    dep: seq[int32] # per pattern: structural nesting depth
    rules: seq[PatId] # RuleId -> pattern, NoPat until defined
    names: seq[string]
    ruleIds: Table[string, RuleId]
    ruleNul: seq[bool]
    startRule: RuleId
    sealed: bool
    steps: int # remaining budget while judging
    jdepth: int # judgment nesting while judging

const
  NoPat = PatId(-1)
  NoRule* = RuleId(-1)
  AllKinds* = {low(BlKind) .. high(BlKind)}
  DefaultBudget* = 1_000_000
  MaxPatternDepth* = 1024
    ## structural nesting a pattern may reach; building past it is a
    ## `GrammarError`, a residual reaching it while judging refuses
  MaxJudgeDepth* = 800
    ## judgment nesting before refusal; sized so judging fits small
    ## thread stacks and debug call-depth tracking with room to spare

# ================ PATTERN IDENTITY ================

func `==`(a, b: Pattern): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of pEmpty, pNotAllowed:
    true
  of pChoice, pGroup:
    a.left == b.left and a.right == b.right
  of pStar:
    a.body == b.body
  of pKind:
    a.kinds == b.kinds and a.req == b.req and a.len == b.len
  of pLit:
    a.lit == b.lit
  of pFrame:
    a.frameKind == b.frameKind and a.frameReq == b.frameReq and a.children == b.children
  of pRef:
    a.rule == b.rule

func hash(p: Pattern): Hash =
  # discriminator plus the active branch, so it tracks the type
  var h: Hash = 0
  for _, f in p.fieldPairs:
    h = h !& hash(f)
  !$h

# ================ POOL ================

func nulOf(g: Grammar, p: Pattern): bool =
  case p.kind
  of pEmpty, pStar:
    true
  of pNotAllowed, pKind, pLit, pFrame:
    false
  of pChoice:
    g.nul[p.left] or g.nul[p.right]
  of pGroup:
    g.nul[p.left] and g.nul[p.right]
  of pRef:
    g.ruleNul[p.rule]

func depOf(g: Grammar, p: Pattern): int32 =
  case p.kind
  of pEmpty, pNotAllowed, pKind, pLit, pRef:
    1
  of pChoice, pGroup:
    1 + max(g.dep[p.left], g.dep[p.right])
  of pStar:
    1 + g.dep[p.body]
  of pFrame:
    1 + g.dep[p.children]

func intern(g: var Grammar, p: Pattern): PatId =
  let d = g.depOf(p)
  if d > MaxPatternDepth:
    # checked before the table is touched, so refusal leaves no orphan
    if g.sealed:
      raise newException(BudgetError, "the residual is too deep to keep judging")
    raise newException(
      GrammarError, "pattern nesting exceeds MaxPatternDepth (" & $MaxPatternDepth & ")"
    )
  let fresh = PatId(g.pats.len)
  result = g.ids.mgetOrPut(p, fresh)
  if result == fresh:
    g.nul.add g.nulOf(p)
    g.dep.add d
    g.pats.add p

func initGrammar*(): Grammar =
  Grammar(startRule: NoRule)

# ================ CONSTRUCTORS ================
# Smart constructors normalize on the way in: choice is ACI with
# notAllowed as unit, group drops empty and is annihilated by
# notAllowed, star collapses. Equal patterns share one id.

func empty*(g: var Grammar): PatId =
  g.intern Pattern(kind: pEmpty)

func never*(g: var Grammar): PatId =
  g.intern Pattern(kind: pNotAllowed)

func addAlts(g: Grammar, p: PatId, acc: var seq[PatId]) =
  case g.pats[p].kind
  of pChoice:
    g.addAlts(g.pats[p].left, acc)
    g.addAlts(g.pats[p].right, acc)
  of pNotAllowed:
    discard
  else:
    acc.add p

func balanced(g: var Grammar, ops: seq[PatId], lo, hi: int): PatId =
  ## the canonical choice tree over sorted, deduplicated alternatives
  if lo + 1 == hi:
    return ops[lo]
  let mid = (lo + hi) div 2
  let l = g.balanced(ops, lo, mid)
  let r = g.balanced(ops, mid, hi)
  g.intern Pattern(kind: pChoice, left: l, right: r)

func choice*(g: var Grammar, alts: varargs[PatId]): PatId =
  if alts.len == 2:
    # the judgment hot path: units and echoes answer with an existing
    # id, exact because pooled choices are already ACI-normal
    let (a, b) = (alts[0], alts[1])
    if a == b or g.pats[a].kind == pNotAllowed:
      return b
    if g.pats[b].kind == pNotAllowed:
      return a
  var ops: seq[PatId]
  for a in alts:
    g.addAlts(a, ops)
  if ops.len == 0:
    return g.never
  ops.sort()
  ops = ops.deduplicate(isSorted = true)
  # balanced over the ACI-normal alternatives: a wide vocabulary is a
  # shallow pattern, so walks never recurse with its width
  g.balanced(ops, 0, ops.len)

func addParts(g: Grammar, p: PatId, acc: var seq[PatId]): bool =
  ## false when the whole group is annihilated
  case g.pats[p].kind
  of pGroup:
    g.addParts(g.pats[p].left, acc) and g.addParts(g.pats[p].right, acc)
  of pNotAllowed:
    false
  of pEmpty:
    true
  else:
    acc.add p
    true

func group*(g: var Grammar, parts: varargs[PatId]): PatId =
  if parts.len == 2:
    # the judgment hot path: a unit or annihilator answers with an
    # existing id, exact because pooled groups are already right-nested
    # with interned suffixes
    let (a, b) = (parts[0], parts[1])
    if g.pats[a].kind == pNotAllowed or g.pats[b].kind == pEmpty:
      return a
    if g.pats[b].kind == pNotAllowed or g.pats[a].kind == pEmpty:
      return b
  var ops: seq[PatId]
  for p in parts:
    if not g.addParts(p, ops):
      return g.never
  if ops.len == 0:
    return g.empty
  result = ops[^1]
  for i in countdown(ops.len - 2, 0):
    result = g.intern Pattern(kind: pGroup, left: ops[i], right: result)

func star*(g: var Grammar, p: PatId): PatId =
  case g.pats[p].kind
  of pEmpty, pNotAllowed:
    g.empty
  of pStar:
    p
  else:
    g.intern Pattern(kind: pStar, body: p)

func kindOf*(g: var Grammar, kinds: set[BlKind], req = mrInert, len = -1): PatId =
  ## one value drawn from `kinds`; `len` pins the payload length
  g.intern Pattern(kind: pKind, kinds: kinds, req: req, len: len)

func any*(g: var Grammar, req = mrInert): PatId =
  g.kindOf(AllKinds, req)

func lit*(g: var Grammar, v: Value): PatId =
  ## one value equal to `v`, mark-exactly
  g.intern Pattern(kind: pLit, lit: v)

func frame*(g: var Grammar, kind: BlKind, children: PatId, req = mrInert): PatId =
  doAssert kind in {bList, bRecord, bDict, bSet}, "frame wants a frame kind"
  g.intern Pattern(kind: pFrame, frameKind: kind, frameReq: req, children: children)

# ================ SUGAR ================

func opt*(g: var Grammar, p: PatId): PatId =
  g.choice(p, g.empty)

func plus*(g: var Grammar, p: PatId): PatId =
  g.group(p, g.star(p))

func entry*(g: var Grammar, key, val: PatId): PatId =
  ## one dictionary entry: the key then the value
  g.group(key, val)

func entry*(g: var Grammar, key: Value, val: PatId): PatId =
  g.entry(g.lit(key), val)

func rest*(g: var Grammar): PatId =
  ## any further values, marked or not
  g.star(g.any(mrAny))

func restEntries*(g: var Grammar): PatId =
  ## any further dictionary entries
  g.star(g.entry(g.any(mrAny), g.any(mrAny)))

func gapped*(g: var Grammar, gap: PatId, parts: openArray[PatId]): PatId =
  ## `parts` in order with `gap` interleaved at every position — the
  ## shape of openness for keyed frames, where unknowns sort anywhere
  var ps = @[gap]
  for p in parts:
    ps.add p
    ps.add gap
  g.group(ps)

func rec*(g: var Grammar, head: Value, fields: varargs[PatId]): PatId =
  ## a record with this exact head and these fields
  g.frame(bRecord, g.group(@[g.lit(head)] & @fields))

func openRec*(g: var Grammar, head: Value, fields: varargs[PatId]): PatId =
  ## a record with at least this head and these fields
  g.rec(head, @fields & g.rest())

func knownEntries(
    g: var Grammar,
    required: openArray[(Value, PatId)],
    optional: openArray[(Value, PatId)],
): seq[PatId] =
  ## entry patterns in canonical key order
  var known: seq[(Value, PatId)]
  for (k, p) in required:
    known.add (k, g.entry(k, p))
  for (k, p) in optional:
    known.add (k, g.opt(g.entry(k, p)))
  known = known.sortedByIt(it[0])
  for i, (k, e) in known:
    if i > 0 and known[i - 1][0] == k:
      raise newException(GrammarError, "duplicate dictionary key in shape")
    result.add e

func dictOf*(
    g: var Grammar,
    required: openArray[(Value, PatId)],
    optional: openArray[(Value, PatId)] = [],
): PatId =
  ## a closed dictionary shape: exactly these entries
  g.frame(bDict, g.group(g.knownEntries(required, optional)))

func openDict*(
    g: var Grammar,
    required: openArray[(Value, PatId)],
    optional: openArray[(Value, PatId)] = [],
): PatId =
  ## an open dictionary shape: at least these entries. Optional entries
  ## are refused: the unknown-entry rest would absorb a mistyped one,
  ## so the option demands nothing — that needs saying "any entry but
  ## these keys", which the pattern algebra cannot say
  if optional.len > 0:
    raise newException(
      GrammarError,
      "optional entries are vacuous in an open dictionary; close the dictionary or drop the option",
    )
  g.frame(bDict, g.gapped(g.restEntries(), g.knownEntries(required, [])))

func litMembers(g: var Grammar, members: openArray[Value]): seq[PatId] =
  ## member literals in canonical order; the set constructor owns the
  ## sort-and-dedup policy, so shapes and real sets cannot drift
  for m in set(@members).elements:
    result.add g.lit(m)

func setOf*(g: var Grammar, members: openArray[Value]): PatId =
  ## a closed set shape: exactly these members
  g.frame(bSet, g.group(g.litMembers(members)))

func openSet*(g: var Grammar, members: openArray[Value]): PatId =
  ## an open set shape: at least these members
  g.frame(bSet, g.gapped(g.rest(), g.litMembers(members)))

# ================ RULES ================

func refTo*(g: var Grammar, name: string): PatId =
  ## a reference to the named rule; the rule may be defined later
  doAssert not g.sealed, "the grammar is sealed; references are fixed"
  var r = g.ruleIds.getOrDefault(name, NoRule)
  if r == NoRule:
    r = RuleId(g.rules.len)
    g.rules.add NoPat
    g.names.add name
    g.ruleNul.add false
    g.ruleIds[name] = r
  g.intern Pattern(kind: pRef, rule: r)

func rule*(g: var Grammar, name: string, p: PatId): PatId {.discardable.} =
  ## define the named rule; answers a reference to it
  doAssert not g.sealed, "the grammar is sealed; rules are fixed"
  result = g.refTo(name)
  let r = g.pats[result].rule
  if g.rules[r] != NoPat:
    raise newException(GrammarError, "rule defined twice: " & name)
  g.rules[r] = p

func ruleNames*(g: Grammar): seq[string] =
  ## the rules this grammar defines, in definition order
  g.names

func rulePattern*(g: Grammar, name: string): PatId =
  ## the pattern a rule names, for the walks that take one
  let r = g.ruleIds.getOrDefault(name, NoRule)
  doAssert r != NoRule, "unknown rule: " & name
  g.rules[r]

func patCount*(g: Grammar): int =
  ## pool size: how much automaton this grammar has learned
  g.pats.len

# ================ SEALING ================

func levelRefs(g: Grammar, p: PatId, acc: var seq[RuleId]) =
  ## rules reachable without crossing a frame
  case g.pats[p].kind
  of pChoice, pGroup:
    g.levelRefs(g.pats[p].left, acc)
    g.levelRefs(g.pats[p].right, acc)
  of pStar:
    g.levelRefs(g.pats[p].body, acc)
  of pRef:
    acc.add g.pats[p].rule
  else:
    discard

type Color = enum
  white
  grey
  black

func checkLevel(g: Grammar) =
  ## the recursion law: a rule may reach itself only through a frame.
  ## Recursion through frames is the recursion of the value space and
  ## is welcome. Recursion among siblings would let a sequence count —
  ## S := empty | a S b admits aⁿbⁿ — and with counting go the finite
  ## automaton, bounded residuals, and every decidable question the
  ## algebra is promised on; so the sibling layer stays regular. This
  ## subsumes the unguarded case: a rule reaching itself without
  ## consuming never crossed a frame either.
  var edges = newSeq[seq[RuleId]](g.rules.len)
  for r in 0 ..< g.rules.len:
    g.levelRefs(g.rules[r], edges[r])
  var color = newSeq[Color](g.rules.len)
  for root in 0 ..< g.rules.len:
    if color[root] != white:
      continue
    color[root] = grey
    var stack = @[(RuleId(root), 0)]
    while stack.len > 0:
      let (r, i) = stack[^1]
      if i < edges[r].len:
        stack[^1][1] = i + 1
        let s = edges[r][i]
        case color[s]
        of white:
          color[s] = grey
          stack.add (s, 0)
        of grey:
          raise newException(
            GrammarError,
            "same-level recursion through rule: " & g.names[s] &
              "; recursion must cross a frame",
          )
        of black:
          discard
      else:
        color[r] = black
        discard stack.pop

type Par = enum
  parUnknown # admits no sequence at all
  parEven
  parOdd
  parMixed

func parJoin(a, b: Par): Par =
  if a == parUnknown:
    b
  elif b == parUnknown:
    a
  elif a == b:
    a
  else:
    parMixed

func parAdd(a, b: Par): Par =
  if a == parUnknown or b == parUnknown:
    parUnknown
  elif a == parMixed or b == parMixed:
    parMixed
  elif a == b:
    parEven
  else:
    parOdd

func parOf(g: Grammar, i: int, par: seq[Par], ruleP: seq[Par]): Par =
  ## one shallow step, children read from the settling arrays
  case g.pats[i].kind
  of pEmpty:
    parEven
  of pNotAllowed:
    parUnknown
  of pKind, pLit, pFrame:
    parOdd
  of pChoice:
    parJoin(par[g.pats[i].left], par[g.pats[i].right])
  of pGroup:
    parAdd(par[g.pats[i].left], par[g.pats[i].right])
  of pStar:
    case par[g.pats[i].body]
    of parEven, parUnknown: parEven
    else: parMixed
  of pRef:
    ruleP[g.pats[i].rule]

func reaches(g: Grammar, root, target: PatId): bool =
  ## does the tree under `root` contain `target`, expanding each rule once
  var seenPat = newSeq[bool](g.pats.len)
  var seenRule = newSeq[bool](g.rules.len)
  var stack = @[root]
  while stack.len > 0:
    let p = stack.pop
    if p == target:
      return true
    if seenPat[p]:
      continue
    seenPat[p] = true
    case g.pats[p].kind
    of pChoice, pGroup:
      stack.add g.pats[p].left
      stack.add g.pats[p].right
    of pStar:
      stack.add g.pats[p].body
    of pFrame:
      stack.add g.pats[p].children
    of pRef:
      let r = g.pats[p].rule
      if not seenRule[r] and g.rules[r] != NoPat:
        seenRule[r] = true
        stack.add g.rules[r]
    else:
      discard

func blameRule(g: Grammar, p: PatId): RuleId =
  ## the first rule whose pattern reaches `p`
  for r in 0 ..< g.rules.len:
    if g.reaches(g.rules[r], p):
      return RuleId(r)
  NoRule

func blame(g: Grammar, p: PatId): string =
  ## the rule to name in an error message
  let r = g.blameRule(p)
  if r != NoRule:
    " in rule '" & g.names[r] & "'"
  else:
    ""

func checkParity(g: Grammar) =
  ## the dictionary parity law: patterns in dictionary position admit an
  ## even count of values on every path, or keys meet value patterns.
  ## Per-pattern parities to a fixpoint like nullability — the pool is a
  ## DAG, and walking it as a tree re-walks every shared subtree
  var par = newSeq[Par](g.pats.len)
  var ruleP = newSeq[Par](g.rules.len)
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< g.pats.len:
      let p = g.parOf(i, par, ruleP)
      if p != par[i]:
        par[i] = p
        changed = true
    for r in 0 ..< g.rules.len:
      let p = par[g.rules[r]]
      if p != ruleP[r]:
        ruleP[r] = p
        changed = true
  for i in 0 ..< g.pats.len:
    if g.pats[i].kind == pFrame and g.pats[i].frameKind == bDict:
      if par[g.pats[i].children] in {parOdd, parMixed}:
        raise newException(
          GrammarError,
          "dictionary children may admit an odd count of values" & g.blame(PatId(i)) &
            "; build entries with entry/dictOf/openDict",
        )

func seal*(g: var Grammar, start = "") =
  ## finish building: check rules, nullability, guardedness, parity.
  ## Judging an unsealed grammar is a defect.
  doAssert not g.sealed, "grammar already sealed"
  for r in 0 ..< g.rules.len:
    if g.rules[r] == NoPat:
      raise newException(GrammarError, "rule never defined: " & g.names[r])
  if start != "":
    g.startRule = g.ruleIds.getOrDefault(start, NoRule)
    if g.startRule == NoRule:
      raise newException(GrammarError, "start rule unknown: " & start)
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< g.pats.len:
      let n = g.nulOf(g.pats[i])
      if n != g.nul[i]:
        g.nul[i] = n
        changed = true
    for r in 0 ..< g.rules.len:
      let n = g.nul[g.rules[r]]
      if n != g.ruleNul[r]:
        g.ruleNul[r] = n
        changed = true
  g.checkLevel()
  g.checkParity()
  g.sealed = true

# ================ JUDGMENT ================

func markOk(req: MarkReq, v: Value): bool =
  case req
  of mrInert:
    not v.marked
  of mrMarked:
    v.marked
  of mrAny:
    true

func deriv(g: var Grammar, p: PatId, v: Value): PatId

func admits(g: var Grammar, p: PatId, v: Value): bool =
  case g.pats[p].kind
  of pKind:
    v.kind in g.pats[p].kinds and markOk(g.pats[p].req, v) and
      (g.pats[p].len < 0 or v.payloadLength == g.pats[p].len)
  of pLit:
    v == g.pats[p].lit
  of pFrame:
    if v.kind != g.pats[p].frameKind or not markOk(g.pats[p].frameReq, v):
      return false
    # children spells every frame the matcher's way: record head then
    # fields, dict keys and values alternating, set members in order
    let dead = g.never
    var res = g.pats[p].children
    for c in v.children:
      res = g.deriv(res, c)
      if res == dead:
        return false
    g.nul[res]
  else:
    false # sequence units and combinators admit no single value here

func deriv(g: var Grammar, p: PatId, v: Value): PatId =
  ## the residual of `p` after consuming `v`
  dec g.steps
  if g.steps <= 0:
    raise newException(BudgetError, "judgment budget spent")
  inc g.jdepth
  if g.jdepth > MaxJudgeDepth:
    # refusal, not a crash: nesting is stack, and stack is not the
    # budget's to bound. The counter resets with the next judgment.
    raise newException(BudgetError, "judgment nesting too deep")
  result =
    case g.pats[p].kind
    of pEmpty, pNotAllowed:
      g.never
    of pChoice:
      let (l, r) = (g.pats[p].left, g.pats[p].right)
      g.choice(g.deriv(l, v), g.deriv(r, v))
    of pGroup:
      let (l, r) = (g.pats[p].left, g.pats[p].right)
      let dl = g.group(g.deriv(l, v), r)
      if g.nul[l]:
        g.choice(dl, g.deriv(r, v))
      else:
        dl
    of pStar:
      let b = g.pats[p].body
      g.group(g.deriv(b, v), p)
    of pRef:
      g.deriv(g.rules[g.pats[p].rule], v)
    of pKind, pLit, pFrame:
      if g.admits(p, v): g.empty else: g.never
  dec g.jdepth

func judgeRule(g: var Grammar, r: RuleId, v: Value, budget: int): bool =
  g.steps = budget
  g.jdepth = 0
  g.nul[g.deriv(g.rules[r], v)]

func matches*(g: var Grammar, name: string, v: Value, budget = DefaultBudget): bool =
  ## does the named rule admit `v`? Raises `BudgetError` on refusal.
  doAssert g.sealed, "seal the grammar before judging"
  let r = g.ruleIds.getOrDefault(name, NoRule)
  doAssert r != NoRule, "unknown rule: " & name
  g.judgeRule(r, v, budget)

func matches*(g: var Grammar, v: Value, budget = DefaultBudget): bool =
  ## does the start rule admit `v`? Raises `BudgetError` on refusal and
  ## `GrammarError` when no rule is named `start` — whether a table
  ## names one is the definition's own data, never a defect here
  doAssert g.sealed, "seal the grammar before judging"
  if g.startRule == NoRule:
    raise newException(GrammarError, "this grammar names no start rule")
  g.judgeRule(g.startRule, v, budget)

template verdictOf(call): Verdict =
  try:
    if call: vAccepted else: vRejected
  except BudgetError:
    vRefused

func judge*(g: var Grammar, name: string, v: Value, budget = DefaultBudget): Verdict =
  ## refusal is an answer: accepted, rejected, or refused on budget
  verdictOf g.matches(name, v, budget)

func judge*(g: var Grammar, v: Value, budget = DefaultBudget): Verdict =
  verdictOf g.matches(v, budget)

func classify*(
    g: var Grammar, v: Value, names: openArray[string], budget = DefaultBudget
): seq[string] =
  ## every named rule that admits `v`. Raises `BudgetError` like
  ## `matches`; judge rule by rule when refusal is an answer.
  for n in names:
    if g.matches(n, v, budget):
      result.add n

proc recognizer*(
    gr: ref Grammar, name: string, budget = DefaultBudget
): proc(v: Value): bool =
  ## a capturable predicate over a shared grammar, for gadget and
  ## dispatch wiring; resolves the rule name now, so a bad name fails
  ## at wiring time instead of per value
  doAssert gr[].sealed, "seal the grammar before judging"
  let r = gr[].ruleIds.getOrDefault(name, NoRule)
  doAssert r != NoRule, "unknown rule: " & name
  result = proc(v: Value): bool =
    gr[].judgeRule(r, v, budget)

# ================ READINGS ================

type Readings* = object
  ## every rule that spoke for a value, and every rule that could not
  ## answer within budget. Recognition is additive: a value may read as
  ## several shapes at once and none of them is the privileged one
  accepted*: seq[string]
  refused*: seq[string]

func readings*(
    g: var Grammar, v: Value, names: openArray[string], budget = DefaultBudget
): Readings =
  ## `classify` that survives refusal: a pathological rule costs its own
  ## lane an answer, never the whole classification
  for n in names:
    case g.judge(n, v, budget)
    of vAccepted:
      result.accepted.add n
    of vRefused:
      result.refused.add n
    of vRejected:
      discard

# ================ PRODUCTIVITY ================
# Which patterns describe at least one sequence, and how cheaply. A
# pattern is empty exactly when it is unproductive, so this answers
# emptiness; the rank it settles on is the well-founded measure
# construction descends.

const Unreachable = int32.high

type Productivity* = object
  ## Indexed by pattern id, and so a reading of one moment's pool. It
  ## stays good for what construction needs, because the patterns a rule
  ## can reach are fixed at sealing and residuals are never among them.
  ok: seq[bool] # per pattern: admits at least one sequence
  some: seq[bool] # per pattern: admits at least one non-empty sequence
  rank: seq[int32] # per pattern: cost of its cheapest sequence
  ruleOk, ruleSome: seq[bool]
  ruleRank: seq[int32]

func satisfiable(k: BlKind, len: int): bool =
  ## is there a value of this kind with this payload length? Frames and
  ## nil carry no payload, and an integer is at least one digit
  if len < 0:
    return true
  case k
  of bNum:
    len >= 1
  of bText, bSym, bBytes:
    true
  of bNil, bList, bRecord, bDict, bSet:
    len == 0

func anyKind(p: Pattern): bool =
  for k in p.kinds:
    if satisfiable(k, p.len):
      return true

func productivity*(g: Grammar): Productivity =
  ## the least fixpoint, exactly like nullability and parity: the pool
  ## is a DAG apart from references, and a reference costs a rank, so
  ## the measure is well-founded through recursion too
  doAssert g.sealed, "seal the grammar before asking what it describes"
  result.ok = newSeq[bool](g.pats.len)
  result.some = newSeq[bool](g.pats.len)
  result.rank = newSeq[int32](g.pats.len)
  result.ruleOk = newSeq[bool](g.rules.len)
  result.ruleSome = newSeq[bool](g.rules.len)
  result.ruleRank = newSeq[int32](g.rules.len)
  for i in 0 ..< g.pats.len:
    result.rank[i] = Unreachable
  for r in 0 ..< g.rules.len:
    result.ruleRank[r] = Unreachable
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< g.pats.len:
      let p = g.pats[i]
      var
        ok = false
        some = false
        rank = Unreachable
      case p.kind
      of pEmpty:
        ok = true
        rank = 0
      of pNotAllowed:
        discard
      of pChoice:
        ok = result.ok[p.left] or result.ok[p.right]
        some = result.some[p.left] or result.some[p.right]
        rank = min(result.rank[p.left], result.rank[p.right])
      of pGroup:
        ok = result.ok[p.left] and result.ok[p.right]
        some =
          (result.some[p.left] and result.ok[p.right]) or
          (result.ok[p.left] and result.some[p.right])
        if ok:
          rank = 1 + max(result.rank[p.left], result.rank[p.right])
      of pStar:
        # zero repetitions always work; a run is only reachable when the
        # body itself consumes something
        ok = true
        some = result.some[p.body]
        rank = 0
      of pKind:
        ok = p.anyKind
        some = ok
        if ok:
          rank = 0
      of pLit:
        ok = true
        some = true
        rank = 0
      of pFrame:
        # a record must carry a head, so its children must consume
        ok =
          result.ok[p.children] and (p.frameKind != bRecord or result.some[p.children])
        some = ok
        if ok:
          rank = 1 + result.rank[p.children]
      of pRef:
        ok = result.ruleOk[p.rule]
        some = result.ruleSome[p.rule]
        if ok:
          rank = 1 + result.ruleRank[p.rule]
      if ok != result.ok[i] or some != result.some[i] or rank != result.rank[i]:
        result.ok[i] = ok
        result.some[i] = some
        result.rank[i] = rank
        changed = true
    for r in 0 ..< g.rules.len:
      let p = g.rules[r]
      if result.ok[p] != result.ruleOk[r] or result.some[p] != result.ruleSome[r] or
          result.rank[p] != result.ruleRank[r]:
        result.ruleOk[r] = result.ok[p]
        result.ruleSome[r] = result.some[p]
        result.ruleRank[r] = result.rank[p]
        changed = true

func isEmpty*(pr: Productivity, p: PatId): bool =
  ## does this pattern describe no sequence at all?
  not pr.ok[p]

func isEmpty*(g: Grammar, name: string): bool =
  ## does this rule describe no sequence at all?
  let r = g.ruleIds.getOrDefault(name, NoRule)
  doAssert r != NoRule, "unknown rule: " & name
  not g.productivity.ruleOk[r]

func emptyRules*(g: Grammar): seq[string] =
  ## the rules that describe nothing. Never a sealing refusal — a dead
  ## alternative can be deliberate — but almost always a mistake
  let pr = g.productivity
  for r in 0 ..< g.rules.len:
    if not pr.ruleOk[r]:
      result.add g.names[r]

# ================ CONSTRUCTION ================
# A productive pattern is a generator. Descending on rank terminates:
# group, frame and reference all rank strictly above what they descend
# into, and choice descends the pool's own DAG.

const
  CheapFirst = [bNil, bNum, bText, bSym, bBytes, bList, bSet, bDict, bRecord]
  KeyedTries = 12
    ## rolls for an already-ordered arrangement of a keyed frame before
    ## falling back to naming only what the shape names

proc genWord(rng: var Rand, n: int): string =
  for _ in 0 ..< n:
    result.add char(ord('a') + rng.rand(25))

proc genAtom(p: Pattern, rng: var Rand, wide: bool): Value =
  ## one value of a kind the pattern admits, of the pinned length when
  ## there is one, cheapest first unless there is size to spend
  var choices: seq[BlKind]
  for k in CheapFirst:
    if k in p.kinds and satisfiable(k, p.len):
      choices.add k
  let k =
    if wide and choices.len > 1:
      choices[rng.rand(choices.len - 1)]
    else:
      choices[0]
  let n = p.len
  result =
    case k
    of bNil:
      nilValue()
    of bNum:
      if n < 0:
        num($(if wide: rng.rand(-99 .. 99) else: 0))
      # canonical decimal of exactly n digits: no leading zero
      else:
        num("1" & repeat('0', n - 1))
    of bText:
      # letters only, so a pinned length stays a pinned byte count: a
      # multi-byte character would spend more payload than it looks
      text(
        if n < 0:
          (if wide: rng.genWord(rng.rand(3)) else: "")
        elif wide:
          rng.genWord(n)
        else:
          repeat('a', n)
      )
    of bSym:
      sym(
        if n < 0:
          (if wide: rng.genWord(1 + rng.rand(2)) else: "a")
        elif wide:
          rng.genWord(n)
        else:
          repeat('a', n)
      )
    of bBytes:
      let count =
        if n < 0:
          (if wide: rng.rand(3) else: 0)
        else:
          n
      var payload = newSeq[byte](count)
      if wide:
        for i in 0 ..< count:
          payload[i] = byte rng.rand(255)
      bytes(payload)
    of bList:
      list()
    of bSet:
      set(@[])
    of bDict:
      dict(@[])
    of bRecord:
      record(@[nilValue()])
  if p.req == mrMarked:
    result = mark result

proc assemble(kind: BlKind, kids: sink seq[Value], req: MarkReq): Option[Value] =
  ## a frame from the constituents a children pattern produced. Keyed
  ## frames canonicalize on the way in, so a generated run that is not
  ## already sorted and unique would come back as a different value than
  ## the one the pattern described: refuse rather than lie
  var v: Value
  case kind
  of bList:
    v = list(kids)
  of bRecord:
    if kids.len == 0:
      return none(Value)
    v = record(kids)
  of bDict:
    if kids.len mod 2 != 0:
      return none(Value)
    var es: seq[(Value, Value)]
    for i in countup(0, kids.len - 2, 2):
      es.add (kids[i], kids[i + 1])
    for i in 1 ..< es.len:
      if cmp(es[i - 1][0], es[i][0]) >= 0:
        return none(Value)
    v = dict(es)
  of bSet:
    for i in 1 ..< kids.len:
      if cmp(kids[i - 1], kids[i]) >= 0:
        return none(Value)
    v = set(kids)
  else:
    return none(Value)
  some(
    if req == mrMarked:
      mark v
    else:
      v
  )

proc genSeq(
    g: Grammar,
    pr: Productivity,
    p: PatId,
    rng: var Rand,
    budget: var int,
    quiet: bool,
    acc: var seq[Value],
): bool =
  ## append one sequence `p` admits. `quiet` suppresses runs of unknown
  ## members: a keyed frame falls back to it when rolling for an
  ## already-ordered arrangement has not come up
  if int(p) >= pr.ok.len or not pr.ok[p]:
    # only rule-reachable patterns are walked and those predate sealing,
    # so a pattern the reading does not cover cannot arise here; answer
    # rather than fault if that ever stops being true
    return false
  let pat = g.pats[p]
  case pat.kind
  of pEmpty:
    true
  of pNotAllowed:
    false
  of pChoice:
    var first, second = pat.left
    if pr.ok[pat.left] and pr.ok[pat.right]:
      let takeLeft =
        if budget > 0:
          rng.rand(1) == 0
        else:
          pr.rank[pat.left] <= pr.rank[pat.right]
      first = if takeLeft: pat.left else: pat.right
      second = if takeLeft: pat.right else: pat.left
    elif pr.ok[pat.right]:
      first = pat.right
      second = pat.right
    let taken = acc.len
    if g.genSeq(pr, first, rng, budget, quiet, acc):
      return true
    if second == first:
      return false
    acc.setLen taken # canonical order may have refused one branch
    g.genSeq(pr, second, rng, budget, quiet, acc)
  of pGroup:
    g.genSeq(pr, pat.left, rng, budget, quiet, acc) and
      g.genSeq(pr, pat.right, rng, budget, quiet, acc)
  of pStar:
    var reps = 0
    if budget > 0 and not quiet and pr.some[pat.body]:
      reps = rng.rand(2)
    for _ in 0 ..< reps:
      dec budget
      if not g.genSeq(pr, pat.body, rng, budget, quiet, acc):
        return false
    true
  of pKind:
    let wide = budget > 0
    dec budget
    acc.add genAtom(pat, rng, wide)
    true
  of pLit:
    dec budget
    acc.add pat.lit
    true
  of pFrame:
    dec budget
    # A keyed frame canonicalizes whatever it is handed, so a run of
    # members it does not name has to come out already in order or it
    # would land somewhere the pattern never spelled. Roll for an
    # ordered arrangement, and fall back to naming nothing rather than
    # to answering nothing: the quiet attempt always arranges
    let keyed = pat.frameKind in {bDict, bSet}
    let tries = if keyed and budget > 0: KeyedTries else: 1
    for attempt in 0 ..< tries:
      var kids: seq[Value]
      var spend = budget
      if g.genSeq(pr, pat.children, rng, spend, keyed and attempt == tries - 1, kids):
        let v = assemble(pat.frameKind, kids, pat.frameReq)
        if v.isSome:
          budget = spend
          acc.add v.get
          return true
    false
  of pRef:
    g.genSeq(pr, g.rules[pat.rule], rng, budget, quiet, acc)

proc generate*(
    g: Grammar, pr: Productivity, p: PatId, rng: var Rand, size = 0
): Option[Value] =
  ## a value this pattern admits, when the pattern describes one value.
  ## `size` is how much structure to spend past the cheapest answer;
  ## with none, this is the smallest value the pattern describes
  var acc: seq[Value]
  var budget = size
  if not g.genSeq(pr, p, rng, budget, false, acc) or acc.len != 1:
    return none(Value)
  some acc[0]

proc generate*(g: Grammar, name: string, rng: var Rand, size = 0): Option[Value] =
  let r = g.ruleIds.getOrDefault(name, NoRule)
  doAssert r != NoRule, "unknown rule: " & name
  g.generate(g.productivity, g.rules[r], rng, size)

proc witness*(g: Grammar, name: string): Option[Value] =
  ## the smallest value the rule describes
  var rng = initRand(1)
  g.generate(name, rng, 0)

proc counterexamples*(
    a: var Grammar,
    ruleA: string,
    b: var Grammar,
    ruleB: string,
    rng: var Rand,
    tries = 100,
    size = 6,
    budget = DefaultBudget,
): seq[Value] =
  ## values `a` describes that `b` does not, by building them. Finding
  ## none is not a proof: sampling can refute an inclusion, never
  ## establish one. The smallest value goes first, since a shape's
  ## boundary is where its cheapest answer sits
  let pr = a.productivity
  let p = a.rulePattern(ruleA)
  var seen: seq[Value]
  for i in 0 ..< tries:
    let v = a.generate(pr, p, rng, if i == 0: 0 else: size)
    if v.isNone or v.get in seen:
      continue
    seen.add v.get
    # only what `a` really admits can speak against `b`
    if a.judge(ruleA, v.get, budget) != vAccepted:
      continue
    if b.judge(ruleB, v.get, budget) == vRejected:
      result.add v.get

# ================ LOADING ================
# The grammar dialect: a marked `(grammar {name: pattern, …})` record.
# In pattern position, marked records are operators and a marked symbol
# is a rule reference; everything inert is the shape itself — an inert
# frame is a template, an inert atom a literal, and a fully inert
# subtree means exact equality under both readings. Loading is
# all-or-nothing: any spelling outside the dialect is a GrammarError,
# and the sealed grammar's own laws do the rest of the refusing. Loader
# recursion follows value depth, which is the decoder's boundary.

func refuse(what: string) {.noreturn.} =
  raise newException(GrammarError, what)

func fullyInert(v: Value): bool =
  ## no mark anywhere below: the template and literal readings coincide
  if v.marked:
    return false

  for c in v.allChildren:
    if c.marked:
      return false
  true

func opHead(v: Value): string =
  ## the operator name of a marked record, "" when there is none
  if v.isKind(bRecord) and v.marked and v.head.isKind(bSym) and not v.head.marked:
    string(v.head.text)
  else:
    ""

func loadPattern(g: var Grammar, v: Value): PatId

func loadSeq(g: var Grammar, vs: seq[Value]): seq[PatId] =
  for v in vs:
    result.add g.loadPattern(v)

func keyLiteral(v: Value): Value =
  ## dictionary template keys are literals: a fully inert value as
  ## itself, or a (lit …) escape. A pattern key would sort by its own
  ## spelling, which says nothing about where its matches fall
  if v.fullyInert:
    v
  elif v.opHead == "lit" and v.tail.len == 1:
    v.tail[0]
  else:
    refuse "dictionary template keys are literals; escape one with (lit …)"

func pinnedLength(v: Value, ops: seq[Value]): int =
  ## the optional length operand of a scalar kind operator
  if ops.len == 0:
    return -1
  if ops.len > 1 or ops[0].marked or ops[0].kind != bNum:
    refuse "(" & v.opHead & " …) takes one inert number, a payload length"
  try:
    result = parseInt(string(ops[0].num))
  except ValueError:
    refuse "(" & v.opHead & " …): unreadable length"
  if result < 0:
    refuse "(" & v.opHead & " …): a length is not negative"

func loadTemplate(g: var Grammar, v: Value, req: MarkReq): PatId =
  ## an inert frame as the shape itself: children are patterns
  case v.kind
  of bList, bRecord:
    var ps: seq[PatId]
    for c in v.children:
      ps.add g.loadPattern(c)
    g.frame(v.kind, g.group(ps), req)
  of bDict:
    # a value in (? …) means the whole entry is optional: a present
    # key demands its value, so the two options coincide
    var required, optional: seq[(Value, PatId)]
    for (k, val) in v.entries:
      let key = keyLiteral(k)
      if val.opHead == "?":
        optional.add (key, g.group(g.loadSeq(val.tail)))
      else:
        required.add (key, g.loadPattern(val))
    g.frame(bDict, g.group(g.knownEntries(required, optional)), req)
  of bSet:
    # members are literals; a (* …) member is a run of unknowns
    # matching its body, interleaved anywhere since sets are unordered
    var lits: seq[Value]
    var runs: seq[PatId]
    for m in v.elements:
      if m.fullyInert:
        lits.add m
      elif m.opHead == "lit" and m.tail.len == 1:
        lits.add m.tail[0]
      elif m.opHead == "*":
        runs.add g.group(g.loadSeq(m.tail))
      else:
        refuse "set template members are literals or (* …) runs"
    if runs.len == 0:
      g.frame(bSet, g.group(g.litMembers(lits)), req)
    else:
      g.frame(bSet, g.gapped(g.star(g.choice(runs)), g.litMembers(lits)), req)
  else:
    refuse "a template is a frame; an inert atom is already a literal"

func loadOpen(g: var Grammar, v: Value, req: MarkReq): PatId =
  ## (open T): the template with unknowns admitted — trailing for
  ## positional frames, interleaved at every gap for keyed ones
  if v.marked or not v.isFrame:
    refuse "(open …) takes an inert frame template"
  case v.kind
  of bList, bRecord:
    var ps: seq[PatId]
    for c in v.children:
      ps.add g.loadPattern(c)
    g.frame(v.kind, g.group(ps & g.rest()), req)
  of bDict:
    var required: seq[(Value, PatId)]
    for (k, val) in v.entries:
      if val.opHead == "?":
        refuse "optional entries are vacuous in an open dictionary; close the dictionary or drop the option"
      required.add (keyLiteral(k), g.loadPattern(val))
    g.frame(bDict, g.gapped(g.restEntries(), g.knownEntries(required, [])), req)
  of bSet:
    var lits: seq[Value]
    for m in v.elements:
      if m.fullyInert:
        lits.add m
      elif m.opHead == "lit" and m.tail.len == 1:
        lits.add m.tail[0]
      else:
        refuse "a (* …) run is vacuous in an open set; close the set or drop the run"
    g.frame(bSet, g.gapped(g.rest(), g.litMembers(lits)), req)
  else:
    discard # unreachable: isFrame guarded above
    g.never

func loadDemand(g: var Grammar, v: Value, req: MarkReq): PatId =
  ## the operand of (marked …) or (anymark …): a kind operator, a
  ## template, an (open …), or a choice of these — the demand lowers
  ## onto the pattern's own mark field, never a mode
  if not v.marked:
    if v.isFrame:
      return g.loadTemplate(v, req)
    refuse "a mark demand wraps shapes; a marked literal is spelled (lit …)"
  case v.opHead
  of "any":
    if v.tail.len > 0:
      refuse "(any) takes nothing"
    g.any(req)
  of "num":
    g.kindOf({bNum}, req, pinnedLength(v, v.tail))
  of "text":
    g.kindOf({bText}, req, pinnedLength(v, v.tail))
  of "sym":
    g.kindOf({bSym}, req, pinnedLength(v, v.tail))
  of "bytes":
    g.kindOf({bBytes}, req, pinnedLength(v, v.tail))
  of "list", "record", "dict", "set":
    let fk =
      case v.opHead
      of "list": bList
      of "record": bRecord
      of "dict": bDict
      else: bSet
    let ops = v.tail
    if ops.len == 0:
      g.kindOf({fk}, req)
    else:
      g.frame(fk, g.group(g.loadSeq(ops)), req)
  of "open":
    if v.tail.len != 1:
      refuse "(open …) takes one template"
    g.loadOpen(v.tail[0], req)
  of "or":
    var alts: seq[PatId]
    for a in v.tail:
      alts.add g.loadDemand(a, req)
    g.choice(alts)
  else:
    refuse "a mark demand wraps kinds, templates, (open …), or a choice of them"

func loadPattern(g: var Grammar, v: Value): PatId =
  if not v.marked:
    if v.isFrame:
      return g.loadTemplate(v, mrInert)
    return g.lit(v) # an inert atom is itself
  case v.kind
  of bSym:
    g.refTo(string(v.text))
  of bRecord:
    let op = v.opHead
    case op
    of "any", "num", "text", "sym", "bytes", "list", "record", "dict", "set", "open":
      g.loadDemand(v, mrInert)
    of "or":
      g.choice(g.loadSeq(v.tail))
    of "cat":
      g.group(g.loadSeq(v.tail))
    of "*":
      g.star(g.group(g.loadSeq(v.tail)))
    of "+":
      g.plus(g.group(g.loadSeq(v.tail)))
    of "?":
      g.opt(g.group(g.loadSeq(v.tail)))
    of "lit":
      if v.tail.len != 1:
        refuse "(lit …) takes exactly one value"
      g.lit(v.tail[0])
    of "marked":
      if v.tail.len != 1:
        refuse "(marked …) takes exactly one shape"
      g.loadDemand(v.tail[0], mrMarked)
    of "anymark":
      if v.tail.len != 1:
        refuse "(anymark …) takes exactly one shape"
      g.loadDemand(v.tail[0], mrAny)
    of "":
      refuse "an operator names itself with an inert symbol head"
    else:
      refuse "unknown operator: " & op
  else:
    refuse "a marked " & $v.kind &
      " is not a pattern; a marked literal is spelled (lit …)"

func load*(v: Value): Grammar =
  ## read the grammar dialect: a marked `(grammar {name: pattern, …})`
  ## record whose rule table is a dictionary — so rule order is not
  ## spellable, duplicate names cannot arrive, and equal rule tables are
  ## equal values. The rule named `start`, when present, is the start.
  ## All-or-nothing: refuses with GrammarError on any spelling outside
  ## the dialect and on everything sealing refuses.
  if not v.marked or v.opHead != "grammar":
    refuse "a grammar is a marked (grammar {…}) record"
  let ops = v.tail
  if ops.len != 1 or ops[0].marked or ops[0].kind != bDict:
    refuse "(grammar …) holds one inert dictionary of rules"
  result = initGrammar()
  var hasStart = false
  # declare every rule first, so definition order is the table's own
  # canonical key order rather than first-mention order
  for (k, _) in ops[0].entries:
    if k.marked or k.kind != bSym:
      refuse "rule names are inert symbols"
    let name = string(k.text)
    if name == "start":
      hasStart = true
    discard result.refTo(name)
  for (k, pat) in ops[0].entries:
    result.rule(string(k.text), result.loadPattern(pat))
  result.seal(start = if hasStart: "start" else: "")

func readGrammar*(text: string): Grammar =
  ## read a bare rule table — a dictionary in the grammar dialect —
  ## wrap it as the marked (grammar …) record, and load it: the
  ## ergonomic door for local definitions. A dialect that travels or
  ## is named by digest is always the whole `(grammar …)` value
  load(mark record(sym"grammar", readValue(text)))

const grammarOfGrammar =
  readValue"""
`(grammar {
  start: `(marked (grammar `(dict `(* `(sym) `pattern))))

  pattern: `(or nil `(num) `(text) `(sym) `(bytes) `ref `template `operator)
  ref: `(marked `(sym))

  template: `(or `(list `(* `pattern))
                 `(record `(+ `pattern))
                 `(dict `(* `key `pattern))
                 `(set `(* `setmember)))
  key: `(or `fullyinert `litop)
  setmember: `(or `key `(marked (* `(* `pattern))))
  fullyinert: `(or nil `(num) `(text) `(sym) `(bytes)
                  `(list `(* `fullyinert))
                  `(record `(+ `fullyinert))
                  `(dict `(* `fullyinert `fullyinert))
                  `(set `(* `fullyinert)))

  operator: `(or `kindop `litop `openop `demandop `combop)
  kindop: `(marked `(or (any)
                        (num `(? `(num)))
                        (text `(? `(num)))
                        (sym `(? `(num)))
                        (bytes `(? `(num)))
                        (list `(* `pattern))
                        (record `(* `pattern))
                        (dict `(* `pattern))
                        (set `(* `pattern))))
  combop: `(marked `(or (or `(* `pattern))
                        (cat `(* `pattern))
                        (* `(* `pattern))
                        (+ `(* `pattern))
                        (? `(* `pattern))))
  litop: `(marked (lit `(anymark `(any))))
  openop: `(marked (open `opentarget))
  opentarget: `(or `(list `(* `pattern))
                   `(record `(+ `pattern))
                   `(dict `(* `key `pattern))
                   `(set `(* `key)))
  demandop: `(marked `(or (marked `demandable) (anymark `demandable)))
  demandable: `(or `kindop `template `openop `(marked (or `(* `demandable))))
})
"""

func grammarGrammar*(): Value =
  ## the grammar dialect described in itself
  grammarOfGrammar

# ================ UNPARSING ================
# A pattern back into the dialect, in operator normal form. This is for
# reading and for diagnosis, never for identity: the spelling it emits
# describes the same language by a different definition, so a grammar
# round-tripped through here is a different dialect by digest.

func opv(name: string, ops: varargs[Value]): Value =
  record(@[sym(name)] & @ops, marked = true)

func opName(k: BlKind): string =
  case k
  of bNil:
    "nil"
  # never an operator; nil is spelled as the literal
  of bNum:
    "num"
  of bText:
    "text"
  of bSym:
    "sym"
  of bBytes:
    "bytes"
  of bList:
    "list"
  of bRecord:
    "record"
  of bDict:
    "dict"
  of bSet:
    "set"

func demanded(v: Value, req: MarkReq): Value =
  case req
  of mrInert:
    v
  of mrMarked:
    opv("marked", v)
  of mrAny:
    opv("anymark", v)

func unparse*(g: Grammar, p: PatId): Value

func operands(g: Grammar, p: PatId): seq[Value] =
  ## a sequence pattern as an operand list, since the quantifiers read
  ## their operands as one implicit cat
  case g.pats[p].kind
  of pEmpty:
    @[]
  of pGroup:
    g.operands(g.pats[p].left) & g.operands(g.pats[p].right)
  else:
    @[g.unparse(p)]

func unparseKind(p: Pattern): Value =
  ## kinds, mark demand, and any pinned length. Nil is a literal rather
  ## than an operator, and a demand cannot wrap a literal, so a kind set
  ## holding nil splits into a choice with the demand on the other half
  if p.kinds == AllKinds and p.len < 0:
    return demanded(opv"any", p.req)
  var ops: seq[Value]
  for k in low(BlKind) .. high(BlKind):
    if k == bNil or k notin p.kinds:
      continue
    if k in {bNum, bText, bSym, bBytes}:
      # a scalar spells its own length, so keep the kind even when no
      # payload satisfies it: the spelling should show what was written
      if p.len >= 0:
        ops.add opv(opName(k), num($p.len))
      else:
        ops.add opv(opName(k))
    elif satisfiable(k, p.len):
      # a frame operator carries no length, so a kind that the length
      # has already excluded cannot be spelled without widening
      ops.add opv(opName(k))
  var alts: seq[Value]
  if ops.len == 1:
    alts.add demanded(ops[0], p.req)
  elif ops.len > 1:
    alts.add demanded(opv("or", ops), p.req)
  if bNil in p.kinds and satisfiable(bNil, p.len):
    if p.req != mrMarked:
      alts.add nilValue()
    if p.req != mrInert:
      alts.add opv("lit", mark nilValue())
  case alts.len
  of 0:
    opv"or"
  # nothing is admitted
  of 1:
    alts[0]
  else:
    opv("or", alts)

func unparse*(g: Grammar, p: PatId): Value =
  ## one pattern as a dialect value
  let pat = g.pats[p]
  case pat.kind
  of pEmpty:
    opv"cat"
  of pNotAllowed:
    opv"or"
  of pChoice:
    var alts: seq[PatId]
    g.addAlts(p, alts)
    if alts.len == 0:
      return opv"or"
    opv("or", alts.mapIt(g.unparse(it)))
  of pGroup:
    opv("cat", g.operands(p))
  of pStar:
    opv("*", g.operands(pat.body))
  of pKind:
    unparseKind(pat)
  of pLit:
    # a fully inert value is its own pattern; anything carrying a mark
    # would read as an operator or a reference, so it needs the escape.
    # A fully inert frame written this way reads back as a template
    # rather than a literal, which is the same language by the dialect's
    # own rule that the two readings coincide there, so writing out
    # settles after a second round rather than the first
    if pat.lit.fullyInert:
      pat.lit
    else:
      opv("lit", pat.lit)
  of pFrame:
    var ops = g.operands(pat.children)
    if ops.len == 0:
      # a bare frame operator means any frame of that kind, so an empty
      # children pattern has to be spelled
      ops = @[opv"cat"]
    demanded(opv(opName(pat.frameKind), ops), pat.frameReq)
  of pRef:
    sym(g.names[pat.rule], marked = true)

func unparse*(g: Grammar): Value =
  ## the whole grammar as a `(grammar {…})` value
  doAssert g.sealed, "seal the grammar before writing it out"
  var es: seq[(Value, Value)]
  for r in 0 ..< g.rules.len:
    es.add (sym(g.names[r]), g.unparse(g.rules[r]))
  mark record(sym"grammar", dict(es))

# ================ EXPECTATION ================

func firstsInto(g: Grammar, p: PatId, seen: var seq[bool], acc: var seq[PatId]) =
  if seen[p]:
    return
  seen[p] = true
  let pat = g.pats[p]
  case pat.kind
  of pEmpty, pNotAllowed:
    discard
  of pChoice:
    g.firstsInto(pat.left, seen, acc)
    g.firstsInto(pat.right, seen, acc)
  of pGroup:
    g.firstsInto(pat.left, seen, acc)
    if g.nul[pat.left]:
      g.firstsInto(pat.right, seen, acc)
  of pStar:
    g.firstsInto(pat.body, seen, acc)
  of pRef:
    g.firstsInto(g.rules[pat.rule], seen, acc)
  of pKind, pLit, pFrame:
    acc.add p

func firsts*(g: Grammar, p: PatId): seq[PatId] =
  ## the leaf patterns that could consume the next value. A frame is one
  ## letter here: what is inside it is not head position
  doAssert g.sealed, "seal the grammar before asking what it admits"
  var seen = newSeq[bool](g.pats.len)
  g.firstsInto(p, seen, result)
  result.sort()

# ================ EXPLANATION ================
# Where a value stopped satisfying a rule. The position is exact, not a
# guess: a residual is the union of every reading still alive, so when
# it dies at a constituent, every reading died there. Only the descent
# into that constituent is judgment, and it declines to guess — it
# descends when exactly one frame pattern could have been meant.

const MaxExpected* = 8

type Miss* = object
  path*: seq[int] ## constituent indices from the judged value
  found*: Option[Value] ## the constituent that stopped it; none when it ended early
  expected*: seq[Value] ## what could have stood there, as patterns
  more*: int ## expectations past the cap
  complete*: bool ## the shape could also have ended here

func foldPos(
    g: var Grammar, start: PatId, vs: openArray[Value]
): tuple[ok: bool, idx: int, res: PatId] =
  ## consume `vs`; on failure `res` is the residual facing `vs[idx]`
  var res = start
  let dead = g.never
  for i in 0 ..< vs.len:
    let nxt = g.deriv(res, vs[i])
    if nxt == dead:
      return (false, i, res)
    res = nxt
  (g.nul[res], vs.len, res)

func missAt(
    g: var Grammar, p: PatId, vs: seq[Value], base: seq[int], top: bool, cap: int
): Option[Miss] =
  let (ok, idx, res) = g.foldPos(p, vs)
  if ok:
    return none(Miss)
  let heads = g.firsts(res)
  let here =
    if top:
      @[] # the judged value itself
    elif idx < vs.len:
      base & @[idx] # this constituent
    else:
      base # the frame ran out of constituents
  if idx < vs.len:
    let child = vs[idx]
    var
      cand = NoPat
      n = 0
    for h in heads:
      if g.pats[h].kind == pFrame and g.pats[h].frameKind == child.kind and
          markOk(g.pats[h].frameReq, child):
        inc n
        cand = h
    if n == 1:
      var kids: seq[Value]
      for c in child.children:
        kids.add c
      let deeper = g.missAt(g.pats[cand].children, kids, here, false, cap)
      if deeper.isSome:
        return deeper
  var exp: seq[Value]
  for h in heads:
    if exp.len >= cap:
      break
    exp.add g.unparse(h)
  some Miss(
    path: here,
    found: (if idx < vs.len: some(vs[idx]) else: none(Value)),
    expected: exp,
    more: heads.len - exp.len,
    complete: g.nul[res],
  )

func explain*(
    g: var Grammar, name: string, v: Value, budget = DefaultBudget, cap = MaxExpected
): Option[Miss] =
  ## why the named rule does not admit `v`; none when it does. Refusal
  ## raises `BudgetError`, exactly as judging does
  doAssert g.sealed, "seal the grammar before judging"
  let r = g.ruleIds.getOrDefault(name, NoRule)
  doAssert r != NoRule, "unknown rule: " & name
  g.steps = budget
  g.jdepth = 0
  g.missAt(g.rules[r], @[v], @[], true, cap)

func explain*(
    g: var Grammar, v: Value, budget = DefaultBudget, cap = MaxExpected
): Option[Miss] =
  doAssert g.sealed, "seal the grammar before judging"
  if g.startRule == NoRule:
    raise newException(GrammarError, "this grammar names no start rule")
  g.steps = budget
  g.jdepth = 0
  g.missAt(g.rules[g.startRule], @[v], @[], true, cap)

func toValue*(m: Miss): Value =
  ## a miss as an ordinary value, so diagnosis stays in the stream
  var es = @[(sym"at", list(m.path.mapIt(num($it)))), (sym"expected", list(m.expected))]
  if m.found.isSome:
    es.add (sym"found", m.found.get)
  if m.more > 0:
    es.add (sym"more", num($m.more))
  es.add (
    sym"flags",
    set(
      if m.complete:
        @[sym"complete"]
      else:
        @[]
    ),
  )
  record(sym"miss", dict(es))

# ================ LINT ================

type Finding* = object
  rule*: string
  reason*: string
  pattern*: Value

func reachable(g: Grammar): seq[bool] =
  ## the patterns some rule can reach
  result = newSeq[bool](g.pats.len)
  var stack: seq[PatId]
  for r in 0 ..< g.rules.len:
    stack.add g.rules[r]
  while stack.len > 0:
    let p = stack.pop
    if result[p]:
      continue
    result[p] = true
    let pat = g.pats[p]
    case pat.kind
    of pChoice, pGroup:
      stack.add pat.left
      stack.add pat.right
    of pStar:
      stack.add pat.body
    of pFrame:
      stack.add pat.children
    else:
      discard

func lint*(g: Grammar): seq[Finding] =
  ## patterns that describe nothing. The algebra's absences make vacuity
  ## quiet — an alternative that can never be taken reads exactly like
  ## one that can — so it is worth asking on purpose
  let pr = g.productivity
  var dead: seq[string]
  for r in 0 ..< g.rules.len:
    if not pr.ruleOk[r]:
      dead.add g.names[r]
      result.add Finding(
        rule: g.names[r], reason: "describes no value", pattern: g.unparse(g.rules[r])
      )
  let live = g.reachable
  for i in 0 ..< g.pats.len:
    if not live[i] or g.pats[i].kind != pChoice:
      continue
    for side in [g.pats[i].left, g.pats[i].right]:
      if pr.ok[side] or g.pats[side].kind == pNotAllowed:
        continue
      let owner = g.blameRule(PatId(i))
      if owner == NoRule or g.names[owner] in dead:
        continue # a rule already reported whole says it better
      result.add Finding(
        rule: g.names[owner],
        reason: "alternative describes no value",
        pattern: g.unparse(side),
      )
