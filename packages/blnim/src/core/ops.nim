{.experimental: "strictFuncs".}

import std/algorithm
import ./values

type ValuePred* = proc(v: Value): bool {.noSideEffect.}

template fail(msg: untyped) =
  raise newException(ValueError, msg)

func `[]`*(v: Value, i: int): Option[Value] =
  ## content by position for lists & records
  ## none when out of range or the kind isn't positional
  doAssert(i >= 0, "i cannot be negative")
  if v.isKind({bList, bRecord}) and i < v.items.len:
    return some v.items[i]
  none Value

func `[]`*(v: Value, key: Value): Option[Value] =
  ## For keyed frames, this does a binary search over
  ## the canonical order.
  ## Dicts answer with the value associated with `key`.
  ## 
  ## For positional frames, we try and convert key into
  ## a number to use as an index into the frame. Otherwise
  ## returning none.
  case v.kind
  of bList, bRecord:
    if key.kind != bNum:
      return none Value
    var n: int
    try:
      n = key.num.parseInt()
    except ValueError:
      return none Value
    if n < 0 or n >= v.ravel.len:
      return none Value
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
  ## lists & sets apply f to each item
  ## records apply f to each field
  ## dicts apply f to the values, not the keys
  ## Scalars are returned untouched
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
  ## see the docs for map, this works the same way, but instead of mapping
  ## values, it applies a filter to the values.
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

# ================ STRUCTURAL ALGEBRA ================



func asIndex(k: Value): int =
  if not k.isKind(bNum):
    fail "an index is a number"
  k.num.parseInt()

func merge*(a, b: DictObj): DictObj =
  ## keyed combination; a collision is refused like the decoder would
  var es: seq[Entry]
  for p in pairIndex(a):
    es.add (a[p.key], a[p.val])
  for p in pairIndex(b):
    es.add (b[p.key], b[p.val])
  dictObj(es)

func merge*(a, b: SetObj): SetObj =
  var xs = a.items
  xs.add b.items
  setObj(xs)

func difference*(a, b: SetObj): SetObj =
  ## the elements of a that b lacks; total, like the algebra
  var xs: seq[Value]
  for e in a:
    if binarySearch(b.items, e, cmp) < 0:
      xs.add e
  setObj(xs)

func difference*(a, b: DictObj): DictObj =
  ## the entries of a that b lacks — whole entries, key and value:
  ## a dict is set-like of entries, and nothing lifts it to keys
  var es: seq[Entry]
  for p in pairIndex(a):
    let q = b.find(a[p.key])
    if not q.valid or b[q.val] != a[p.val]:
      es.add (a[p.key], a[p.val])
  dictObj(es)

func put*(a: DictObj, k, v: Value): DictObj =
  ## last wins
  var es: seq[Entry]
  for p in pairIndex(a):
    if a[p.key] != k:
      es.add (a[p.key], a[p.val])
  es.add (k, v)
  dictObj(es)

func put*(xs: sink seq[Value], i: int, v: sink Value): seq[Value] =
  if i < 0 or i >= xs.len:
    fail "nothing under that index"
  result = xs
  result[i] = v

func merge*(a, b: Value): Value =
  if a.isKind(bDict) and b.isKind(bDict):
    dict(merge(a.entries, b.entries), a.marked)
  elif a.isKind(bSet) and b.isKind(bSet):
    set(merge(a.elements, b.elements), a.marked)
  else:
    fail "mismatched frames"

func difference*(a: Value, b: Value): Value =
  ## set algebra is same-kind over set-like frames; anything else,
  ## and any change of reading, casts out loud
  case a.kind
  of bSet:
    if not b.isKind(bSet):
      fail "subtracts a set"
    set(difference(a.elements, b.elements), a.marked)
  of bDict:
    if not b.isKind(bDict):
      fail "subtracts a dict; key-space work casts with keys"
    dict(difference(a.entries, b.entries), a.marked)
  else:
    fail "not set-like; ->set, keys, or vals cast first"

func put*(a: Value, k: Value, v: Value): Value =
  case a.kind
  of bDict: dict(put(a.entries, k, v), a.marked)
  of bList: list(put(a.ravel, k.asIndex, v), a.marked)
  of bRecord: record(put(a.ravel, k.asIndex, v), a.marked)
  of bSet: fail "sets take union"
  else: fail "not a frame"

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
    var es = newSeqOfCap[Entry](pairLen(t.ravel))
    for p in pairIndex(t.ravel):
      es.add (entrySide(t.ravel[p.key], window), entrySide(t.ravel[p.val], window))
    dict(es, t.marked)
  else:
    var xs: seq[Value]
    for c in t.ravel:
      if c.isKind(bNum) and c.marked:
        let k = holeIndex(c, window.len)
        if k > 0:
          xs.add window[^k]
        else:
          let spliced = window[^(-k)]
          if not spliced.isFrame:
            fail "a splice hole names a non-frame"
          xs.add spliced.ravel
      else:
        xs.add fry(c, window)
    case t.kind
    of bList: list(xs, t.marked)
    of bRecord: record(xs, t.marked)
    of bSet: set(xs, t.marked)
    else: t # unreachable: scalars returned above

func fryReach*(t: Value): int =
  ## the deepest hole the template reaches
  if t.isKind(bNum) and t.marked:
    let k = t.num.parseInt()
    if k == 0:
      fail "0! names nothing"
    return abs(k)
  if not t.isFrame:
    return 0
  for c in t.ravel:
    result = max(result, fryReach(c))