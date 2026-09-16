import ../core
import ../lib/blmacro
import ./util

type
  RuleError* = object of CatchableError

  RuleKind* = enum
    rkLit, rkWild

  Shape* = object
    shape*: Value
    holes*: BSet
    case kind*: RuleKind
    of rkWild:
      wild*: Value
    else: discard

  Match* = object
    shape*: Shape
    bindings*: BDict

refuseWith RuleError

proc toBSet*(self: openArray[Value]): BSet =
  result = newBSet()
  for item in self:
    result.incl item

proc toBSet*(self: BSet): BSet =
  self

proc initShape*[H](shape: Value, holes: H, wild: Value): Shape =
  Shape(kind: rkWild, shape: shape, wild: wild, holes: toBSet(holes))

proc initShape*[H](shape: Value, holes: H): Shape =
  Shape(kind: rkLit, shape: shape, holes: toBSet(holes))

proc initMatch*(self: Shape): Match =
  Match(shape: self, bindings: newBDict())

proc initMatch*(self: Shape, bindings: BDict): Match =
  Match(shape: self, bindings: bindings)

proc isWild*(self: Shape, val: Value): bool =
  case self.kind
  of rkWild:
    self.wild == val
  else: false

proc isWild*(self: Match, v: Value): bool =
  self.shape.isWild v

proc isFilled*(self: Match): bool =
  self.shape.holes == self.bindings.keys

proc bindHole(self: var Match, hole, val: Value) =
  if hole in self.bindings:
    guard self.bindings[hole] == val, "mismatched holes"
  else:
    self.bindings[hole] = val

proc holes*(self: Match): BSet =
  self.shape.holes

proc bindValue*(self: var Match, shape, val: Value): bool =
  template ensureBind(a, b): untyped =
    if not self.bindValue(a, b):
      return

  if self.isWild shape:
    return true
  
  if shape in self.holes and shape.mark == val.mark:
    self.bindHole shape, val
    return true

  if shape.family != val.family:
    return

  case shape.kind
  of bList, bRec:
    for _, a, b in lockstep(shape.items, val.items):
      ensureBind(a, b)
    true
  of bDict:
    for k in keys(shape.dict):
      if k notin val.dict:
        return
      guard k notin self.holes, "dict holes aren't supported yet"
      ensureBind(k, k)
      ensureBind(shape[k], val[k])
    let rest = val.dict - shape.dict
    echo rest.toValue
    true
  of bSet:
    for v in shape.els:
      if v notin val.els:
        return
      guard v notin self.holes, "set holes aren't supported yet"
      ensureBind(v, v)
    true
  else:
    shape == val

proc bindValue*(self: var Match, val: Value): auto =
  self.bindValue(self.shape.shape, val)

proc add*(self: var Match, val: Value): bool {.discardable.} =
  ## alias for `bindValue`
  self.bindValue(val)

proc injectValue*(self: Match, v: Value): Value =
  ## replace instances of self.holes in v with their binding
  if v in self.holes:
    self.bindings[v]
  elif v.kind in bList..bSet:
    v.map(proc(v: Value): Value = self.injectValue(v))
  else:
    v

proc maybeInject*(self: Match, v: Value): Value =
  ## like inject value, but will passthrough if the match isn't filled
  if self.isFilled:
    self.injectValue v
  else:
    v

proc `@`*(self: Shape): Match =
  initMatch(self)

proc `//`*(self: Match, val: Value): Value =
  ## alias for `injectValue`
  self.injectValue(val)

proc `?/`*(self: Match, val: Value): Value =
  ## alias for `maybeInject`
  self.maybeInject val

proc fromValue*(_: type Shape, val: Value): Shape =
  guard val.kind == bRec, "expected a record"
  guard val.head == bl shape, "expected a shape head"
  case val.items.len:
  of 3: # (shape ex holes)
    initShape val/1, (val/2).els
  of 4: # (shape ex holes wild)
    initShape val/1, (val/2).els, val/3
  else:
    refuse "expected (shape ex holes) or (shape ex wild holes)"

proc toShape*(self: Value): Shape =
  Shape.fromValue(self)

template withMatch*(self: Shape, name, body: untyped): untyped =
  block:
    var name = initMatch self
    body

template withMatch*(self: Shape, body: untyped): untyped =
  withMatch(self, match):
    body

proc extract*(self: Shape, val: Value): Value =
  self.withMatch:
    if bindValue(match, val) and isFilled(match):
      initDict(match.bindings)
    else:
      initDict()

proc extract*(self: Shape): auto =
  proc(val: Value): Value =
    self.extract(val)

proc inject*(self: Shape, bindings: Value): Value =
  guard bindings.kind == bDict, "expected a dict"
  self.withMatch:
    match.bindings = bindings.dict / self.holes
    match // self.shape

proc inject*(self: Shape): auto =
  proc(bindings: Value): Value =
    self.inject(bindings)

proc extract*(self, val: Value): auto =
  extract toShape(self), val

proc inject*(self, bindings: Value): auto =
  inject toShape(self), bindings

when isMainModule:
  var
    shape = toShape rv"(shape !(cmd arg) {cmd arg})"
    one = rv"!(listen-to-more jungle)"
    collection = rv"""{
      !(foo bar)
      !(do something)
      !(ping pong)
    }"""

  echo "one: ", shape.extract one
  echo "collection: ", collection.map shape.extract

  collection.incl (shape.inject rv"{cmd: turn-on arg: swag}")
  echo collection