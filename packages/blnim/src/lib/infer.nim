{.experimental: "strictFuncs".}

## infer: a dialect from a corpus.
##
##   let shape = infer(values)        # a !(grammar {…}) value
##
## Reading a grammar out of data is guessing, so the guesses are few,
## named, and each one is a rule you can argue with rather than a
## threshold buried in a walk.
##
## **What earns a name.** A record's head is zero-vocabulary tagging:
## two records sharing a head are the same kind of thing, wherever they
## turn up. So every inert-symbol head becomes one rule, and its fields
## merge across the whole corpus. Nothing else is named — lists,
## dictionaries and sets are spelled where they stand. Recursion falls
## out: a record that contains its own head refers to its own rule, and
## that reference crosses a frame, which is the only recursion the
## model allows anyway.
##
## **What generalises.** An atom becomes its kind, except where the
## values repeat: a value seen many times over a small vocabulary is
## vocabulary and is kept as literals; a value that never repeats is a
## name and becomes !(sym). That is the one real judgement here and it
## is stated as a rule rather than a ratio pulled from the air.
##
## **What stays exact.** A bytes payload whose length never varies is
## pinned, because that is what a key or a digest is. Marks are kept
## per kind, because a marked value is a different utterance. Dictionary
## keys present in every instance are required and the rest optional --
## unless the keys keep changing, in which case the dictionary is a map
## and gets quantified instead of enumerated.
##
## **What is refused.** Nothing is inferred that cannot be checked:
## `infer` hands back a value, `load` decides whether it is a grammar,
## and `conforms` says whether the corpus it came from still fits. An
## unsound inference is a bug, and it is meant to be caught rather than
## shipped.

import std/[algorithm, sets, hashes, tables]
import ../core/values
import ./grammar

type
  Settings* = object
    enumMax*: int ## most distinct values a slot may hold and still read as vocabulary
    enumRepeat*: int ## how many times over, on average, those values must have been seen
    positionalMax*: int ## longest fixed-length list still spelled position by position
    mapRatio*: int
      ## distinct keys per key-per-dictionary before a dictionary reads
      ## as a map rather than a shape
    litCap*: int ## distinct atoms tracked per slot before giving up on vocabulary

  Slot = ref object
    seen: int
    kinds: set[BlKind]
    markedKinds, inertKinds: set[BlKind]
    lits: Table[Value, int]
    litsFull: bool
    byteLens: HashSet[int]
    list, rec: Positional
    setAny: Slot
    dictSeen, keyTotal: int
    dictKeys: Table[Value, int]
    dictVals: Table[Value, Slot]
    anyKey, anyVal: Slot
    heads: Table[Value, int]

  Positional = object
    seen: int
    lens: HashSet[int]
    at: seq[Slot]
    any: Slot

  Shape = ref object
    seen: int
    lens: HashSet[int]
    at: seq[Slot] ## fields after the head
    marked, inert: bool

  Inference = object
    top: Slot
    shapes: Table[Value, Shape]
    names: Table[Value, string]
    cfg: Settings

func defaults*(): Settings =
  Settings(enumMax: 16, enumRepeat: 2, positionalMax: 8, mapRatio: 3, litCap: 512)

func newSlot(): Slot =
  Slot()

func slotAt(s: var seq[Slot], i: int): Slot =
  while s.len <= i:
    s.add newSlot()
  s[i]

# ================ OBSERVING ================

proc observe(inf: var Inference, slot: Slot, v: Value)

proc observeInto(inf: var Inference, s: var Slot, v: Value) =
  if s == nil:
    s = newSlot()
  inf.observe(s, v)

proc observePositional(inf: var Inference, p: var Positional, v: Value) =
  inc p.seen
  var n = 0
  for c in v.children:
    inf.observe(p.at.slotAt(n), c)
    inf.observeInto(p.any, c)
    inc n
  p.lens.incl n

proc nameFor(inf: var Inference, head: Value): string =
  if inf.names.hasKey(head):
    return inf.names[head]
  var base = string(head.text)
  if base.len == 0:
    base = "unnamed"
  var name = base
  var n = 1
  # `start` is spoken for, and so is any head already spelled this way
  var taken: HashSet[string]
  for _, used in inf.names:
    taken.incl used
  while name == "start" or name in taken:
    inc n
    name = base & "-" & $n
  inf.names[head] = name
  name

proc observe(inf: var Inference, slot: Slot, v: Value) =
  inc slot.seen
  slot.kinds.incl v.kind
  if v.marked:
    slot.markedKinds.incl v.kind
  else:
    slot.inertKinds.incl v.kind
  case v.kind
  of bNil, bNum, bText, bSym, bBytes:
    if v.kind == bBytes:
      slot.byteLens.incl v.payloadLength
    if not slot.litsFull:
      if slot.lits.len >= inf.cfg.litCap and not slot.lits.hasKey(v):
        slot.litsFull = true
        slot.lits.clear()
      else:
        slot.lits.mgetOrPut(v, 0) += 1
  of bList:
    inf.observePositional(slot.list, v)
  of bSet:
    for m in v.elements:
      inf.observeInto(slot.setAny, m)
  of bDict:
    inc slot.dictSeen
    for (k, val) in v.entries:
      slot.dictKeys.mgetOrPut(k, 0) += 1
      inc slot.keyTotal
      if not slot.dictVals.hasKey(k):
        slot.dictVals[k] = newSlot()
      inf.observe(slot.dictVals[k], val)
      inf.observeInto(slot.anyKey, k)
      inf.observeInto(slot.anyVal, val)
  of bRecord:
    let head = v.head
    if head.isKind(bSym) and not head.marked:
      slot.heads.mgetOrPut(head, 0) += 1
      discard inf.nameFor(head)
      if not inf.shapes.hasKey(head):
        inf.shapes[head] = Shape()
      let sh = inf.shapes[head]
      inc sh.seen
      if v.marked:
        sh.marked = true
      else:
        sh.inert = true
      let fields = v.tail
      sh.lens.incl fields.len
      for i, f in fields:
        inf.observe(sh.at.slotAt(i), f)
    else:
      inf.observePositional(slot.rec, v)

# ================ SPELLING ================
# The dialect vocabulary — opv, opName, demanded, fullyInert — is the
# grammar module's own; only the sighting-to-demand mapping is ours.

func demandOf(marked, inert: bool): MarkReq =
  ## what a slot's sightings demand: both polarities is any, marked
  ## alone is marked, inert (or nothing seen) is inert
  if marked and inert:
    mrAny
  elif marked:
    mrMarked
  else:
    mrInert

func demanded(v: Value, marked, inert: bool): Value =
  demanded(v, demandOf(marked, inert))

func literal(v: Value): Value =
  ## a value standing for itself; anything carrying a mark needs the
  ## escape, or it would read as an operator or a reference
  if v.fullyInert:
    v
  else:
    opv("lit", v)

func anyPattern(): Value =
  opv("anymark", opv("any"))

func combine(alts: seq[Value]): Value =
  case alts.len
  of 0:
    opv("or")
  # nothing was ever seen here
  of 1:
    alts[0]
  else:
    opv("or", alts)

func sortedByCe(vs: seq[Value]): seq[Value] =
  result = vs
  result.sort(cmp)

proc render(inf: Inference, slot: Slot): Value

proc vocabulary(inf: Inference, slot: Slot, k: BlKind): seq[Value] =
  ## the literals of this kind, when the slot reads as vocabulary: few
  ## enough of them, and each seen more than once over.
  ##
  ## Only symbols are ever asked. A symbol is the kind that acts as an
  ## identifier rather than as a sequence of characters, which is the
  ## whole reason it is its own kind — so a small repeating set of them
  ## is vocabulary. Text, integers and bytes are content: a corpus where
  ## they happen not to vary says nothing about the language, and
  ## freezing them would describe the sample instead of the shape
  if k != bSym or slot.litsFull:
    return @[]
  var
    vs: seq[Value]
    total = 0
  for v, n in slot.lits:
    if v.kind == k:
      vs.add v
      total += n
  if vs.len == 0 or vs.len > inf.cfg.enumMax:
    return @[]
  if total < vs.len * inf.cfg.enumRepeat:
    return @[] # never repeats: a name, not a word
  sortedByCe(vs)

proc atomPattern(inf: Inference, slot: Slot, k: BlKind): seq[Value] =
  let marked = k in slot.markedKinds
  let inert = k in slot.inertKinds
  if k == bNil:
    # nil has no kind operator: it is spelled as the literal it is
    if inert:
      result.add nilValue()
    if marked:
      result.add opv("lit", mark nilValue())
    return
  let words = inf.vocabulary(slot, k)
  if words.len > 0:
    for w in words:
      result.add literal(w)
    return
  var op = opv(opName(k))
  if k == bBytes and slot.byteLens.len == 1:
    # one length, every time: that is what a key or a digest is
    for n in slot.byteLens:
      op = opv("bytes", num($n))
  result.add demanded(op, marked, inert)

proc renderPositional(
    inf: Inference, p: Positional, kind: BlKind, marked, inert: bool
): Value =
  if p.seen == 0:
    return opv("or")
  var single = -1
  if p.lens.len == 1:
    for n in p.lens:
      single = n
  if single >= 0 and single <= inf.cfg.positionalMax and (
    kind != bRecord or single >= 1
  ):
    # always the same length, short enough to say position by position
    var items: seq[Value]
    for i in 0 ..< single:
      items.add inf.render(p.at[i])
    if items.len == 0:
      # a bare frame operator means any frame of that kind, so an empty
      # one has to spell its emptiness or it would widen to everything
      items.add opv("cat")
    return demanded(opv(opName(kind), items), marked, inert)
  let body =
    if p.any == nil:
      anyPattern()
    else:
      inf.render(p.any)
  demanded(opv(opName(kind), opv("*", body)), marked, inert)

proc renderSet(inf: Inference, slot: Slot): Value =
  let marked = bSet in slot.markedKinds
  let inert = bSet in slot.inertKinds
  if slot.setAny == nil:
    # every set seen was empty: say that, rather than any set at all
    return demanded(opv("set", opv("cat")), marked, inert)
  demanded(opv("set", opv("*", inf.render(slot.setAny))), marked, inert)

proc renderDict(inf: Inference, slot: Slot): Value =
  let marked = bDict in slot.markedKinds
  let inert = bDict in slot.inertKinds
  let perDict =
    if slot.dictSeen == 0:
      0
    else:
      slot.keyTotal div slot.dictSeen
  if slot.dictSeen >= 4 and slot.dictKeys.len > max(1, perDict) * inf.cfg.mapRatio:
    # the keys keep changing: this is a map, not a shape, and naming
    # every key seen would describe the corpus rather than the language
    let kp =
      if slot.anyKey == nil:
        anyPattern()
      else:
        inf.render(slot.anyKey)
    let vp =
      if slot.anyVal == nil:
        anyPattern()
      else:
        inf.render(slot.anyVal)
    return demanded(opv("dict", opv("*", kp, vp)), marked, inert)
  var keys: seq[Value]
  for k in slot.dictKeys.keys:
    keys.add k
  keys = sortedByCe(keys)
  var entries: seq[(Value, Value)]
  for k in keys:
    let body = inf.render(slot.dictVals[k])
    let always = slot.dictKeys[k] == slot.dictSeen
    entries.add (
      literal(k),
      if always:
        body
      else:
        opv("?", body),
    )
  demanded(dict(entries), marked, inert)

proc render(inf: Inference, slot: Slot): Value =
  var alts: seq[Value]
  for k in [bNil, bNum, bText, bSym, bBytes]:
    if k in slot.kinds:
      alts.add inf.atomPattern(slot, k)
  if bList in slot.kinds:
    alts.add inf.renderPositional(
      slot.list, bList, bList in slot.markedKinds, bList in slot.inertKinds
    )
  if bSet in slot.kinds:
    alts.add inf.renderSet(slot)
  if bDict in slot.kinds:
    alts.add inf.renderDict(slot)
  var heads: seq[Value]
  for h in slot.heads.keys:
    heads.add h
  for h in sortedByCe(heads):
    alts.add sym(inf.names[h], marked = true)
  if slot.rec.seen > 0:
    alts.add inf.renderPositional(
      slot.rec, bRecord, bRecord in slot.markedKinds, bRecord in slot.inertKinds
    )
  combine(alts)

proc renderShape(inf: Inference, head: Value, sh: Shape): Value =
  ## the rule a record head earns. Fields present every time are
  ## required; the rest trail as one nested option, so a shape that grew
  ## a field still admits what came before it
  var lo = high(int)
  var hi = 0
  for n in sh.lens:
    lo = min(lo, n)
    hi = max(hi, n)
  var tail = newSeq[Value]()
  for i in countdown(hi - 1, lo):
    tail =
      if tail.len == 0:
        @[opv("?", inf.render(sh.at[i]))]
      else:
        @[opv("?", @[inf.render(sh.at[i])] & tail)]
  var items = @[literal(head)]
  for i in 0 ..< lo:
    items.add inf.render(sh.at[i])
  items = items & tail
  let shaped = record(items)
  if sh.marked and sh.inert:
    opv("or", shaped, opv("marked", shaped))
  elif sh.marked:
    opv("marked", shaped)
  else:
    shaped

# ================ THE DOOR ================

proc infer*(values: openArray[Value], cfg = defaults()): Value =
  ## a dialect describing these values, as a !(grammar {…}) value.
  ## Deterministic: the same corpus spells the same grammar, so the
  ## same corpus has the same name
  var inf = Inference(top: newSlot(), cfg: cfg)
  for v in values:
    inf.observe(inf.top, v)
  var rules = @[(sym"start", inf.render(inf.top))]
  var heads: seq[Value]
  for h in inf.shapes.keys:
    heads.add h
  for h in sortedByCe(heads):
    rules.add (sym(inf.names[h]), inf.renderShape(h, inf.shapes[h]))
  mark record(sym"grammar", dict(rules))

proc conforms*(shape: Value, values: openArray[Value], budget = DefaultBudget): int =
  ## how many of these the inferred grammar admits. Anything short of
  ## all of them is a defect in the inference, not a fact about the data
  var g = load(shape)
  for v in values:
    if g.judge(v, budget) == vAccepted:
      inc result
