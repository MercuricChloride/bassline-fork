import ../core
import ./[ops, blmacro]

type
  RuleError* = object of CatchableError

  RuleKind* = enum
    rkLit, rkWild

  Rule* = object
    shape*: Value
    holes*: BSet
    case kind*: RuleKind
    of rkWild:
      wild*: Value
    else: discard

  Match* = object
    rule: Rule
    bindings: BDict

refuseWith RuleError

proc toBSet*(self: openArray[Value]): BSet =
  result = newBSet()
  for item in self:
    result.incl item

proc toBSet*(self: BSet): BSet =
  self

proc initRule*[H](shape: Value, holes: H, wild: Value): Rule =
  Rule(kind: rkWild, shape: shape, wild: wild, holes: toBSet(holes))

proc initRule*[H](shape: Value, holes: H): Rule =
  Rule(kind: rkLit, shape: shape, holes: toBSet(holes))

proc initMatch*(self: Rule): Match =
  Match(rule: self, bindings: newBDict())

proc isWild*(self: Rule, val: Value): bool =
  case self.kind
  of rkWild:
    self.wild == val
  else: false

proc isWild*(self: Match, v: Value): bool =
  self.rule.isWild v

proc isFilled*(self: Match): bool =
  self.rule.holes == self.bindings.keys

proc bindHole(self: var Match, hole, val: Value) =
  if hole in self.bindings:
    guard self.bindings[hole] == val, "mismatched holes"
  else:
    self.bindings[hole] = val

proc holes*(self: Match): BSet =
  self.rule.holes

proc bindValue*(self: var Match, shape, val: Value): bool =
  template ensureBind(a, b): untyped =
    if not self.bindValue(a, b):
      return

  if shape in self.holes:
    self.bindHole shape, val
    return true

  if self.isWild shape:
    return true

  if shape.kind != val.kind or shape.mark != val.mark:
    return

  case shape.kind
  of bList, bRec:
    for _, a, b in lockstep(shape.items, val.items):
      ensureBind(a, b)
    true
  of bSet:
    for a, b in lockstep(shape.els, val.els):
      guard a notin self.holes, "set holes aren't supported yet"
      ensureBind(a, b)
    true
  of bDict:
    for a, b in lockstep(shape.dict, val.dict):
      guard a.key notin self.holes, "set holes aren't supported yet"
      ensureBind(a.key, b.key)
      ensureBind(a.val, b.val)
    true
  else:
    shape == val

proc bindValue*(self: var Match, val: Value): bool =
  self.bindValue(self.rule.shape, val)

proc injectValue*(self: Match, v: Value): Value =
  if v in self.holes:
    self.bindings[v]
  elif v.kind in bList..bDict:
    v.map(proc(v: Value): Value = self.injectValue(v))
  else:
    v

proc maybeInject*(self: Match, v: Value): Value =
  ## like inject value, but will passthrough if the match isn't filled
  if self.isFilled:
    self.injectValue v
  else:
    v

proc `**`*(self: var Match, val: Value): bool {.discardable.} =
  ## alias for `bindValue`
  self.bindValue(val)

proc `//`*(self: Match, val: Value): Value =
  ## alias for `injectValue`
  self.injectValue(val)

proc `/?`*(self: Match, val: Value): Value =
  ## alias for `maybeInject`
  self.maybeInject val

proc fromValue*(_: type Rule, val: Value): Rule =
  guard val.kind == bRec, "expected a record"
  guard val.head == bl rule, "expected a rule head"
  case val.items.len:
  of 3: # (rule ex holes)
    initRule val/1, (val/2).els
  of 4: # (rule ex holes wild)
    initRule val/1, (val/2).els, val/3
  else:
    refuse "expected (rule ex holes) or (rule ex wild holes)"