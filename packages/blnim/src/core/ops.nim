{.experimental: "strictFuncs".}

import std/algorithm
import ./values

type ValuePred* = proc(v: Value): bool {.noSideEffect.}

func hasHead*(v: Value, expected: Value): bool =
  v.isKind(bRecord) and v.head == expected

func `[]`*(v: Value, i: int): Option[Value] =
  ## content by position for lists & records
  ## none when out of range or the kind isn't positional
  doAssert(i >= 0, "i cannot be negative")
  if v.isKind({bList, bRecord}) and i < v.items.len:
    return some v.items[i]
  none Value

func `[]`*(v: Value, key: Value): Option[Value] =
  ## keyed access by binary search over canonical order: a dict
  ## answers with the value under key, a set answers with its own
  ## element equal to key. none when absent or the kind isn't keyed.
  case v.kind
  of bList, bRecord:
    if key.kind != bNum:
      return none Value
    let n = key.num.parseInt()
    some v.ravel[n]
  of bDict:
    let p = v.entries.find(key)
    if p.valid:
      some v.entries[p.val]
    else:
      none Value
  of bSet:
    let i = binarySearch(
      v.ravel,
      key,
      cmp
    )

    if i < 0:
      none Value
    else:
      some v.ravel[i]
  else:
    none Value

func contains*(v: Value, element: Value): bool =
  ## shallow containment
  if not v.isFrame:
    return false
  for c in v.children:
    if c == element:
      return true

func find*(
    v: Value, pred: ValuePred, descendMarked = true
): Option[Value] {.effectsOf: pred.} =
  ## the first value in walk order that pred admits (v itself first),
  ## or none

  if pred(v):
    return some v

  if not descendMarked and v.marked:
    return none Value

  if v.isFrame:
    for c in v.children:
      let r = find(c, pred, descendMarked)
      if r.isSome:
        return r

  none Value

func map*(v: Value, f: proc(x: Value): Value): Value {.effectsOf: f.} =
  ## the same value with f over its content:
  ##
  ## list items, record fields
  ## (the head stays), set elements (the result is reminted, so CE
  ## order returns and collisions dedupe), dict values (keys stay).
  ## Scalars come back untouched, f unapplied. The value's own mark is
  ## preserved. Never raises.
  case v.kind
  of bList:
    var xs = newSeqOfCap[Value](v.items.len)
    for x in v.items:
      xs.add f(x)
    list(xs, v.marked)
  of bRecord:
    var xs = newSeqOfCap[Value](v.items.len)
    xs.add v.items[0]
    for i in 1 ..< v.items.len:
      xs.add f(v.items[i])
    record(xs).mark(v.marked)
  of bSet:
    var xs = newSeqOfCap[Value](v.elements.len)
    for x in v.elements:
      xs.add f(x)
    set(xs).mark(v.marked)
  of bDict:
    var es = newSeqOfCap[Entry](v.entries.len)
    for p in pairIndex(v.ravel):
      es.add (v.ravel[p.key], f(v.ravel[p.val]))
    dict(es).mark(v.marked)
  else:
    v

func filter*(v: Value, pred: proc(x: Value): bool): Value {.effectsOf: pred.} =
  ## the same value keeping the content pred admits: list items, record
  ## fields (the head always stays), set elements, dict entries kept by
  ## their value. Scalars come back untouched. Never raises.
  case v.kind
  of bList:
    var xs: seq[Value]
    for x in v.items:
      if pred(x):
        xs.add x
    list(xs, v.marked)
  of bRecord:
    var xs = @[v.items[0]]
    for i in 1 ..< v.items.len:
      if pred(v.items[i]):
        xs.add v.items[i]
    record(xs).mark(v.marked)
  of bSet:
    var xs: seq[Value]
    for x in v.elements:
      if pred(x):
        xs.add x
    set(xs).mark(v.marked)
  of bDict:
    var es: seq[Entry]
    for p in pairIndex(v.ravel):
      if pred(v.ravel[p.val]):
        es.add (v.ravel[p.key], v.ravel[p.val])
    dict(es).mark(v.marked)
  else:
    v