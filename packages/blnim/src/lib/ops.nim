##[
  Ops implements a handful of useful operations for Bassline.

  I'll add more prose here later.
]##
import pkg/core
import pkg/lib/blmacro

func contains*(v, key: Value): bool =
  case v.kind
  of bSet:
    key in v.els
  of bDict:
    key in v.dict
  else:
    raise newException(ValueError, "contains requires a set / dict")

func `[]`*(v, key: Value): lent Value =
  case v.kind
  of bList, bRec:
    doAssert key.kind == bNum, "[] for a list requires an index"
    return v.items[key.num]
  of bDict:
    return v.dict[key]
  else:
    raise newException(ValueError, "[] requires a list, record, or dict")

func similar*(v, examplar: Value): bool =
  if examplar.kind != v.kind: return
  if examplar.marked != v.marked: return

  case examplar.kind
  of bList:
    if examplar.items.len > v.items.len: return
    for i in 0..<examplar.items.len:
      if not similar(v.items[i], examplar.items[i]):
        return
  of bRec:
    if examplar.items.len > v.items.len: return
    if examplar.items[0] != v.items[0]: return
    for i in 1..<examplar.items.len:
      if not similar(v.items[i], examplar.items[i]): 
        return
  of bDict:
    for key, val in examplar.dict:
      try:
        if not similar(val, v.dict[key]):
          return
      except KeyError:
        return
  of bSet:
    for key, _ in examplar.els:
      if key notin v.els: return
  else: discard

  return true

#[
================ Shapes ================

A shape is a value with holes. A hole is a marked atom and the atom
is its name, aside from `_!` which binds nothing. 

`extract` recognises a value by a shape, where literal parts must match,
and binds it's holes into a dictionary. When a hole is seen twice it
also enforces that it must be the same value. The bindings are a dict 
keyed by the holes' names. 

`inject` fills a shape's holes from bindings, leaving holes without one
as they are, so filling composes. A hole in a dict key or a set member 
has no single answer, so extract refuses such shapes until I implement
unification there.
]#

func isHole*(v: Value): bool =
  v.marked and v.kind in {bNil..bBytes}

func isAnon*(v: Value): bool =
  v == sym("_", true)

func holeName(hole: Value): Value =
  result = hole
  result.marked = false

func hasHoles*(v: Value): bool =
  if isHole(v): return true
  case v.kind
  of bList, bRec:
    for c in v.items:
      if hasHoles(c): return true
  of bDict:
    for k, val in v.dict:
      if hasHoles(k) or hasHoles(val): return true
  of bSet:
    for m in v.els.keys:
      if hasHoles(m): return true
  else: discard
  false

proc extract*(shape, v: Value, bindings: var Value): bool =
  ## returns whether v is shaped like `shape`
  ## and binds the holes into `bindings`
  if bindings.kind != bDict:
    bindings = initDict()
  if isHole(shape):
    if isAnon(shape): return true
    let name = holeName(shape)
    if name in bindings.dict:
      return bindings.dict[name] == v
    bindings.dict[name] = v
    return true
  if shape.kind != v.kind or shape.marked != v.marked:
    return false
  case shape.kind
  of bList, bRec:
    if shape.items.len != v.items.len: return false
    for i in 0 ..< shape.items.len:
      if not extract(shape.items[i], v.items[i], bindings): return false
    true
  of bDict:
    # the shape's keys must be there; keys the value has besides are
    # not its concern
    for k, sv in shape.dict:
      if hasHoles(k):
        raise newException(ValueError, "a hole in a dict key: " & $k)
      if k notin v.dict: return false
      if not extract(sv, v.dict[k], bindings): return false
    true
  of bSet:
    for m in shape.els.keys:
      if hasHoles(m):
        raise newException(ValueError, "a hole in a set member: " & $m)
    shape == v
  else:
    shape == v

proc inject*(shape, bindings: Value): Value =
  ## `shape` with its holes filled from `bindings`
  if isHole(shape):
    if isAnon(shape): return shape
    let name = holeName(shape)
    if bindings.kind == bDict and name in bindings.dict:
      return bindings.dict[name]
    return shape
  case shape.kind
  of bList, bRec:
    var kids = newSeqOfCap[Value](shape.items.len)
    for c in shape.items:
      kids.add inject(c, bindings)
    result = if shape.kind == bList: initList(kids, shape.marked)
             else: initRec(kids, shape.marked)
  of bDict:
    result = initDict(shape.marked)
    for k, val in shape.dict:
      result.dict[inject(k, bindings)] = inject(val, bindings)
  of bSet:
    result = initSet(shape.marked)
    for m in shape.els.keys:
      result.els[inject(m, bindings)] = true
  else:
    result = shape