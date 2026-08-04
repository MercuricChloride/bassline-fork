{.experimental: "strictFuncs".}

import ./values

type ValuePred* = proc(v: Value): bool {.noSideEffect.}

template fail(msg: untyped) =
  raise newException(ValueError, msg)

# Two planes of operation:
#
# READERS take closed Values — reading is what closed values are
# for, and a ValuePred is noSideEffect, so it cannot mutate anything
# a walk borrows through.
#
# RESHAPERS take drafts and return drafts: open a frame, transform
# it, and the caller holds the door. They consume their inputs, so a
# raising callback destroys the in-flight draft (husks unreachable)
# and a capturing closure holds only a moved-from shell. Ops whose
# joins need canonical order demand it via canonicalize — a verifying
# scan when the draft came from a closed value, a real sort only
# when it was built by hand.

# ================ DEEP SEARCH ================
# search is the spelling: the walk visits contents, heads and keys
# included, the value itself first

func seek(
    v: Value, pred: ValuePred, descendMarked: bool, res: var Value
): bool {.effectsOf: pred.} =
  if pred(v):
    res = v
    return true
  if not descendMarked and v.marked:
    return false
  if v.isFrame:
    for c in v.contents:
      if seek(c, pred, descendMarked, res):
        return true
  false

func find*(
    v: Value, pred: ValuePred, descendMarked = true
): Value {.effectsOf: pred.} =
  ## the first value in walk order that pred admits (v itself first),
  ## as an owned copy; nothing admitted refuses
  if not seek(v, pred, descendMarked, result):
    fail "find: nothing admitted"

func walkInto(
    v: Value, pred: ValuePred, into: var OpenFrame, descendMarked: bool
) {.effectsOf: pred.} =
  if pred(v):
    into.add v
  if not descendMarked and v.marked:
    return
  if v.isFrame:
    for c in v.contents:
      walkInto(c, pred, into, descendMarked)

func findInto*(
    v: Value, pred: ValuePred, into: var OpenFrame, descendMarked = true
) {.effectsOf: pred.} =
  ## every value in walk order that pred admits, fed to a draft
  walkInto(v, pred, into, descendMarked)

# ================ SHALLOW REWRITING ================
# the content lens over a draft: heads stay, keys stay, values move.
# A dict mapped by value is still canonical (seal); a mapped set may
# have collided (close); a filtered draft of any kind seals.

func map*(
    b: sink OpenFrame, f: proc(x: sink Value): Value
): OpenFrame {.effectsOf: f.} =
  ## rewrite the draft's children in place;
  ## dicts rewrite the values, never the keys
  result = b
  if result.kind == bDict:
    for _, v in result.mpairs:
      v = f(move v)
  else:
    for x in result.mchildren:
      x = f(move x)

func filter*(
    b: sink OpenFrame, pred: proc(x: Value): bool
): OpenFrame {.effectsOf: pred.} =
  ## keep the children pred admits; dict entries are kept by their
  ## value; a record keeps its head. A drain never judges: a record's
  ## missing head and a dict's odd trailing element survive for the
  ## door to refuse.
  var src = b
  result = open(src.kind, src.marked)
  case src.kind
  of bDict:
    for k, v in src.drainPairs:
      if pred(v):
        result.add(k, v)
    if src.len mod 2 == 1:
      result.add src.take(src.len - 1)
  of bRecord:
    if src.len > 0:
      result.add src.take(0)
    for x in src.drainChildren:
      if pred(x):
        result.add x
  else:
    for x in src.drainChildren:
      if pred(x):
        result.add x

# ================ STRUCTURAL ALGEBRA ================
# reshapers feed drafts and the doors judge. merge and put never
# order anything themselves — close sorts, and a dict collision
# refuses at close exactly like the decoder would. difference, keys
# and vals consume pairwise, so they judge their input dict-wise
# first (canonicalize) — a drain must never launder a collision or
# an odd tail.

func merge*(a: sink OpenFrame, b: sink OpenFrame): OpenFrame =
  ## keyed combination for dicts, union for sets: b feeds into a,
  ## the door judges
  if (a.kind == bDict and b.kind == bDict) or
      (a.kind == bSet and b.kind == bSet):
    result = a
    var sb = b
    for x in sb.drainChildren:
      result.add x
  else:
    fail "mismatched frames"

func difference*(a: sink OpenFrame, b: sink OpenFrame): OpenFrame =
  ## set algebra is same-kind over set-like drafts; anything else,
  ## and any change of reading, casts out loud
  var sa = a
  var sb = b
  case sa.kind
  of bSet:
    if sb.kind != bSet:
      fail "subtracts a set"
    canonicalize(sa)
    let held = close sb
    result = open(bSet, sa.marked)
    for x in sa.drainChildren:
      if x notin held:
        result.add x
  of bDict:
    if sb.kind != bDict:
      fail "subtracts a dict; key-space work casts with keys"
    # the entries of a that b lacks — whole entries, key and value:
    # a dict is set-like of entries, and nothing lifts it to keys
    canonicalize(sa)
    let held = close sb
    result = open(bDict, sa.marked)
    for k, v in sa.drainPairs:
      if held.hasKey(k) and held.at(k) == v:
        continue
      result.add(k, v)
  else:
    fail "not set-like; ->set, keys, or vals cast first"

func put*(a: sink OpenFrame, k: sink Value, v: sink Value): OpenFrame =
  ## last wins for dict drafts; by index for positional drafts, the
  ## head included
  result = a
  case result.kind
  of bDict:
    var vv = v
    for bk, bv in result.mpairs:
      if bk == k:
        bv = move vv
        return
    result.add(k, move vv)
  of bList, bRecord:
    if k.kind != bNum:
      fail "put: a positional frame takes a numeric key"
    var n: int
    try:
      n = k.num.parseInt()
    except ValueError:
      fail "put: not an index"
    if n < 0 or n >= result.len:
      fail "nothing under that index"
    result[n] = v
  of bSet:
    fail "sets take union"
  else:
    fail "not a frame"

func keys*(b: sink OpenFrame): OpenFrame =
  ## a dict draft's key set; judged dict-wise first, so a collision
  ## or an odd tail refuses instead of laundering into set-ness
  var src = b
  if src.kind != bDict:
    fail "not a dict"
  canonicalize(src)
  result = open(bSet, src.marked)
  for k, v in src.drainPairs:
    result.add k

func vals*(b: sink OpenFrame): OpenFrame =
  ## a dict draft's values as a set; same dict-wise judgment, and
  ## value collisions dedupe at the caller's close
  var src = b
  if src.kind != bDict:
    fail "not a dict"
  canonicalize(src)
  result = open(bSet, src.marked)
  for k, v in src.drainPairs:
    result.add v

# ================ FRY ================

func holeIndex(t: Value, window: int): int =
  result = t.num.parseInt()
  if result == 0:
    fail "0! names nothing"
  if abs(result) > window:
    fail "a hole reaches past the window"

func fry*(t: Value, window: openArray[Value]): Value
  ## Factor style value templating.
  ## Unlike factor we don't utilize _ or @ as words
  ## for templating. Instead we use marked numbers
  ## in the template value representing the depth
  ## in the stack to bind.
  ##
  ## So with a stack: `BOTTOM [ a b c ] TOP`
  ## a is 3!, b is 2!, c is 1!
  ##
  ## If a number is negative this is a sign to splice
  ##
  ## So if `a` were a list, we would splice with `-3!`
  ##
  ## The substitution walks the template value only
  ## and isn't recursive

func entrySide(c: Value, window: openArray[Value]): Value =
  ## a dict key or value holds exactly one value: no splicing
  if c.isKind(bNum) and c.marked:
    let k = holeIndex(c, window.len)
    if k < 0:
      fail "cannot splice into a dict entry"
    return window[^k]
  fry(c, window)

func fry*(t: Value, window: openArray[Value]): Value =
  if t.isKind(bNum) and t.marked:
    let k = holeIndex(t, window.len)
    if k < 0:
      fail "nothing to splice into at the top"
    return window[^k]
  if not t.isFrame:
    return t

  case t.kind
  of bDict:
    var b = open(bDict, t.marked)
    for k, v in t.pairs:
      b.add(entrySide(k, window), entrySide(v, window))
    close b
  else:
    # the template walk is the spelling: a record's head is a slot too
    var b = open(t.kind, t.marked)
    for c in t.contents:
      if c.isKind(bNum) and c.marked:
        let k = holeIndex(c, window.len)
        if k > 0:
          b.add window[^k]
        else:
          let spliced = window[^(-k)]
          if not spliced.isFrame:
            fail "a splice hole names a non-frame"
          for x in spliced.contents:
            b.add x
      else:
        b.add fry(c, window)
    close b

func fryReach*(t: Value): int =
  ## the deepest hole the template reaches
  if t.isKind(bNum) and t.marked:
    let k = t.num.parseInt()
    if k == 0:
      fail "0! names nothing"
    return abs(k)
  if not t.isFrame:
    return 0
  for c in t.contents:
    result = max(result, fryReach(c))
