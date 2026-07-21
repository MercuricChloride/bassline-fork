{.experimental: "strictFuncs".}

import std/[algorithm, options]
import values
export options, values

type Pred = proc(v: Value): bool {.noSideEffect.}

func satisfies*(v: Value, preds: openArray[Pred]): bool =
  for p in preds:
    if not p(v):
      return false
  true

func hasHead*(v: Value; expected: Value): bool =
  v.isKind(bRecord) and v.head == expected

func `[]`*(v: Value; i: int): Option[Value] =
  ## content by position for lists & records
  ## none when out of range or the kind isn't positional
  doAssert(i >= 0, "I cannot be negative")
  if v.isKind({bList, bRecord}) and i < v.items.len:
    return some v.items[i]
  
  none Value

func `[]`*(v: Value; key: Value): Option[Value] =
  ## keyed access by binary search over canonical order: a dict
  ## answers with the value under key, a set answers with its own
  ## element equal to key. none when absent or the kind isn't keyed.
  case v.kind
  of bDict:
    let i = seq[(Value, Value)](v.entries).binarySearch(
      key, proc (e: (Value, Value); k: Value): int = cmp(e[0], k))
    if i < 0: none Value else: some v.entries[i][1]
  of bSet:
    let i = seq[Value](v.elements).binarySearch(
      key, proc (e, k: Value): int = cmp(e, k))
    if i < 0: none Value else: some v.elements[i]
  else:
    none Value

func contains*(v: Value, element: Value): bool =
  ## shallow containment
  for c in v.children:
    if c == element:
      return true
  false

func find*(v: Value; pred: proc (x: Value): bool;
           descendMarked = true): Option[Value] {.effectsOf: pred.} =
  ## the first value in walk order that pred admits (v itself first),
  ## or none
  if pred(v):
    return some v
  if not descendMarked and v.marked:
    return none Value
  for c in v.children:
    let r = find(c, pred, descendMarked)
    if r.isSome:
      return r
  none Value

func map*(v: Value; f: proc (x: Value): Value): Value {.effectsOf: f.} =
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
    record(xs, v.marked)
  of bSet:
    var xs = newSeqOfCap[Value](v.elements.len)
    for x in v.elements:
      xs.add f(x)
    values.set(xs, v.marked)
  of bDict:
    var es = newSeqOfCap[(Value, Value)](v.entries.len)
    for e in v.entries:
      es.add (e[0], f(e[1]))
    dict(es, v.marked)
  else:
    v

func filter*(v: Value; pred: proc (x: Value): bool): Value {.effectsOf: pred.} =
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
    record(xs, v.marked)
  of bSet:
    var xs: seq[Value]
    for x in v.elements:
      if pred(x):
        xs.add x
    values.set(xs, v.marked)
  of bDict:
    var es: seq[(Value, Value)]
    for e in v.entries:
      if pred(e[1]):
        es.add e
    dict(es, v.marked)
  else:
    v

func transform*(v: Value; f: proc (x: Value): Value;
                descendMarked = true): Value {.effectsOf: f.} =
  ## bottom-up rewrite of every constituent and then the value itself
  ## -- the spelling view, so record heads and dict keys are rewritten
  ## too. Frames remint on the way up: sets dedupe silently; a rewrite
  ## that collides two dict keys raises ValueError, same as the dict
  ## constructor. With descendMarked = false a marked value is a
  ## fence: f still receives the fence itself (so it can be judged or
  ## replaced), but nothing under it is entered.
  if not descendMarked and v.marked:
    return f(v)
  case v.kind
  of bList, bRecord:
    var xs = newSeqOfCap[Value](v.items.len)
    for x in v.items:
      xs.add transform(x, f, descendMarked)
    if v.kind == bRecord:
      f(record(xs, v.marked))
    else:
      f(list(xs, v.marked))
  of bSet:
    var xs = newSeqOfCap[Value](v.elements.len)
    for x in v.elements:
      xs.add transform(x, f, descendMarked)
    f(values.set(xs, v.marked))
  of bDict:
    var es = newSeqOfCap[(Value, Value)](v.entries.len)
    for e in v.entries:
      es.add (transform(e[0], f, descendMarked),
              transform(e[1], f, descendMarked))
    f(dict(es, v.marked))
  else:
    f(v)
