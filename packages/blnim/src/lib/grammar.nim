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

import std/[algorithm, sequtils, strutils, tables]
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

  GrammarError* = object of CatchableError
    ## a malformed grammar, reported at seal

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

func parityOf(g: Grammar, p: PatId, ruleP: seq[Par]): Par =
  case g.pats[p].kind
  of pEmpty:
    parEven
  of pNotAllowed:
    parUnknown
  of pKind, pLit, pFrame:
    parOdd
  of pChoice:
    parJoin(g.parityOf(g.pats[p].left, ruleP), g.parityOf(g.pats[p].right, ruleP))
  of pGroup:
    parAdd(g.parityOf(g.pats[p].left, ruleP), g.parityOf(g.pats[p].right, ruleP))
  of pStar:
    case g.parityOf(g.pats[p].body, ruleP)
    of parEven, parUnknown: parEven
    else: parMixed
  of pRef:
    ruleP[g.pats[p].rule]

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

func blame(g: Grammar, p: PatId): string =
  ## the first rule whose pattern reaches `p`, for error messages
  for r in 0 ..< g.rules.len:
    if g.reaches(g.rules[r], p):
      return " in rule '" & g.names[r] & "'"

func checkParity(g: Grammar) =
  ## the dictionary parity law: patterns in dictionary position admit an
  ## even count of values on every path, or keys meet value patterns
  var ruleP = newSeq[Par](g.rules.len)
  var changed = true
  while changed:
    changed = false
    for r in 0 ..< g.rules.len:
      let p = g.parityOf(g.rules[r], ruleP)
      if p != ruleP[r]:
        ruleP[r] = p
        changed = true
  for i in 0 ..< g.pats.len:
    if g.pats[i].kind == pFrame and g.pats[i].frameKind == bDict:
      if g.parityOf(g.pats[i].children, ruleP) in {parOdd, parMixed}:
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
  ## does the start rule admit `v`? Raises `BudgetError` on refusal.
  doAssert g.sealed, "seal the grammar before judging"
  doAssert g.startRule != NoRule, "sealed without a start rule"
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
  if v.kind == bRecord and not v.head.marked and v.head.kind == bSym:
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
    refuse "a marked " & $v.kind & " is not a pattern; a marked literal is spelled (lit …)"

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

const grammarOfGrammar = readValue"""
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
  ## the grammar dialect described in itself; the digest of this value
  ## names the schema language. It describes the spelling — the sealing
  ## laws stay judgments, so a value it admits may still refuse to load
  grammarOfGrammar
