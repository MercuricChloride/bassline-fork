##[
  Ops implements a handful of useful operations for Bassline.

  I'll add more prose here later.
]##
import ../core
import blmacro

template refuse(msg: string) =
  raise newException(ValueError, msg)

# ================ Walking & accessing ================

iterator items*(v: Value): Value =
  case v.kind
  of bList, bRec:
    for val in v.items:
      yield val
  of bSet:
    for val,_ in v.els:
      yield val
  of bDict:
    for key, val in v.dict:
      yield key
      yield val
  else: discard

iterator walk*(v: Value): Value {.closure.} =
  case v.kind
  of bList, bRec, bSet, bDict:
    yield v
    for val in v:
      for deep in walk(val):
        yield deep
  else:
    yield v

func contains*(v, key: Value): bool =
  case v.kind
  of bSet:
    key in v.els
  of bDict:
    key in v.dict
  else:
    refuse "contains requires a set / dict"

func `[]`*(v, key: Value): lent Value =
  case v.kind
  of bList, bRec:
    guard key.kind == bNum, "[] for a list requires an index"
    return v.items.data[key.num.toInt]
  of bDict:
    return v.dict[key]
  else:
    refuse "[] requires a list, record, or dict"

# ================ Similarity ================

func similar*(v, examplar: Value): bool =
  if examplar.kind != v.kind: return
  if examplar.mark != v.mark: return

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

A shape is a value with holes. A hole is a mark atom and the atom
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
  v.mark and v.kind in {bNil..bBytes}

func isAnon*(v: Value): bool =
  v == sym("_", true)

func holeName(hole: Value): Value =
  result = hole
  result.mark = false

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
  if shape.kind != v.kind or shape.mark != v.mark:
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
      guard not hasHoles k, "a hole in a dict key: " & $k
      
      if k notin v.dict: return false
      if not extract(sv, v.dict[k], bindings): return false
    true
  of bSet:
    for m in shape.els.keys:
      guard not hasHoles m, "a hole in a set member: " & $m
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
    result = if shape.kind == bList: initList(kids, shape.mark)
             else: initRec(kids, shape.mark)
  of bDict:
    result = initDict(shape.mark)
    for k, val in shape.dict:
      result.dict[inject(k, bindings)] = inject(val, bindings)
  of bSet:
    result = initSet(shape.mark)
    for m in shape.els.keys:
      result.els[inject(m, bindings)] = true
  else:
    result = shape