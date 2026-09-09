##[
  Ops implements a handful of useful operations for Bassline.

  I'll add more prose here later.
]##
import ../core
import ../lib/blmacro

refuseWith ValueError

# ================ Walking & accessing ================

type Family* = tuple[kind: Kind, mark: bool]

func family*(self: SomeValue): Family =
  (self.kind, self.mark)

iterator items*(self: Value): lent Value =
  case self.kind
  of bList, bRec:
    for val in self.items:
      yield val
  of bDict:
    for key, val in self.dict:
      yield key
      yield val
  of bSet:
    for val in self.els:
      yield val
  else: discard

proc forEach*(self: Value, fn: proc(v: Value)) =
  fn(self)
  case self.kind
  of bList, bRec, bSet, bDict:
    for val in self:
      val.forEach fn
  else: discard

proc map*(self: Value, fn: proc(v: Value): Value): Value =
  case self.kind
  of bList:
    initList(self.items.map(fn), self.mark)
  of bRec:
    initRec(self.items.map(fn), self.mark)
  of bDict:
    initDict(self.dict.map(
      proc(k,v: Value): Pair[Value] =
        (fn(k), fn(v))))
  of bSet:
    initSet(self.els.map(fn), self.mark)
  else:
    refuse "cannot unary map over " & $(self.kind)

proc map*(self: Value, fn: proc(k, v: Value): Pair[Value]): Value =
  guard self.kind == bDict, "cannot binary map over" & $(self.kind)
  initDict(self.dict.map(fn), self.mark)

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

func `[]`*(v: Value, key: int): lent Value =
  case v.kind
  of bList, bRec:
    return v.items.data[key]
  else:
    refuse "[] with an int requires a list or record"

proc `[]=`*(self: var Value, key, val: Value) =
  case self.kind
  of bList, bRec:
    guard key.kind == bNum, "[]= for a list requires an index"
    self.items.data[key.num.toInt] = val
  of bDict:
    self.dict[key] = val
  else:
    refuse "[]= requires a list, record, or dict"

proc `[]=`*(self: var Value, key: int, val: Value) =
  case self.kind
  of bList, bRec:
    self.items.data[key] = val
  else:
    refuse "[]= with an int requires a list or record"

proc incl*(self: var Value, val: Value) =
  guard self.kind == bSet, "expected a set"
  self.els.incl val

func `/`*(self: Value, key: Value): lent Value =
  self[key]

func `/`*(self: Value, key: int): lent Value =
  self[key]

# ================ Similarity ================

func similar*(v, examplar: Value): bool =
  template ok = return true

  ensure v.family == examplar.family

  case examplar.kind
  of bList:
    ensure v.items.len >= examplar.items.len
    for _, a, b in lockstep(v.items, examplar.items):
      ensure similar(a, b)
    ok
  of bRec:
    ensure v.items.len >= examplar.items.len
    for i, a, b in lockstep(v.items, examplar.items):
      if i == 0:
        ensure a == b
      else:
        ensure similar(a,b)
    ok
  of bDict:
    for key, val in examplar.dict:
      try:
        ensure similar(val, v[key])
      except KeyError: return false
    ok
  of bSet:
    ensure examplar.els <= v.els
  else: ok

# ================ Prefix ================

func prefixes*(a, b: Value): bool =
  ## Whether `a` is a prefix of `b`: what `b`'s canonical encoding
  ## yields when stopped early, with every frame the stop left open
  ## closed by END. Reflexive. Kind and mark must agree. Among scalars
  ## only equal values are prefixes, since a scalar carries its own
  ## length. In a frame every member but the last must equal `b`'s,
  ## and the last is itself a prefix of `b`'s, since a truncation only
  ## drops a suffix. Dicts and sets compare in canonical order, so a
  ## prefix is a leading run of the sorted members, not a subset.
  ensure a.family == b.family

  case a.kind
  of bNil, bNum, bText, bSym, bBytes:
    ensure a == b
  of bList, bRec:
    let n = a.items.len
    ensure n <= b.items.len
    for i, x, y in lockstep(a.items, b.items):
      if i + 1 == n:
        ensure x.prefixes(y)
      else:
        ensure x == y
  of bDict:
    let n = a.dict.len
    ensure n <= b.dict.len
    var i = 0
    for x, y in lockstep(a.dict, b.dict):
      if i + 1 == n:
        ensure x.key == y.key and x.val.prefixes(y.val)
      else:
        ensure x.key == y.key and x.val == y.val
      inc i
  of bSet:
    let n = a.els.len
    ensure n <= b.els.len
    var i = 0
    for x, y in lockstep(a.els, b.els):
      if i + 1 == n:
        ensure x.prefixes(y)
      else:
        ensure x == y
      inc i
  return true

proc frameKey*(q: ValueView): seq[byte] =
  ## The byte-prefix key that selects exactly the values `q` prefixes
  ## (see `ops.prefixes`): `q`'s CE bytes with one trailing ENDs.
  ## A scalar `q` yields its bytes unchanged
  var v = q
  var opens = 0
  while v.kind in {bList, bRec, bDict, bSet}:
    inc opens
    if v.kind == bDict:
      let es = v.entries
      if es.len == 0 or es[es.len - 1].val.isNil: break
      v = es[es.len - 1].val
    else:
      let cs = v.children
      if cs.len == 0: break
      v = cs[cs.len - 1]
  result = @(q.bytes)
  result.setLen(result.len - opens)

proc frameKey*(q: Value): seq[byte] =
  ## `frameKey` for an in-memory value: through its view.
  frameKey(q.toView)