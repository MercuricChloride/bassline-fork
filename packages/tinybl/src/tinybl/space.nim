import std/sequtils
import ./[micro, micro_macros]

refuseWith BasslineError

type
  Occurence* = object
    case
    of Removed: discard
    of Present:
      n*: Node

  Hook* = ref object of Live
    space: Space
    target: Space
    moving: bool

  Space* = ref object of Live
    kept: seq[Occurence]
    hooks: seq[Hook]
    notifying: bool
    pending: seq[(int, Occurence)]

const
  Append = -1
  Reset = -2
  Skip = -3

func `==`*(a, b: Occurence): bool =
  case a
  of Removed:
    case b
    of Removed: true
    of Present: false
  of Present(x):
    case b
    of Removed: false
    of Present(y): x == y

method added*(self: Hook, i: int) {.base.} =
  discard

method changed*(self: Hook, i: int, old: Occurence) {.base.} =
  discard

method removed*(self: Hook, i: int, old: Occurence) {.base.} =
  discard

method joined*(self: Hook) {.base.} =
  discard

method left*(self: Hook, s: Space) {.base.} =
  discard

method beforeReset*(self: Hook) {.base.} =
  discard

# ================
# Space
# ================

proc len*(self: Space): int =
  self.kept.len

proc contains*(self: Space, i: int): bool =
  i in 0..<self.len

proc `[]`*(self: Space, i: int): lent Occurence =
  return self.kept[i]

iterator attached(self: Space): Hook =
  ## The hooks attached when the loop starts, minus any detached since. A hook
  ## detached during a notification has its slot set to nil, and one attached
  ## during it is past the end, so neither is called for that change.
  let n = self.hooks.len
  for j in 0 ..< n:
    let h = self.hooks[j]
    if not h.isNil:
      yield h

proc apply(self: Space, i: int, occ: sink Occurence, failure: var ref CatchableError) =
  template notify(call: untyped) =
    for h {.inject.} in self.attached:
      try:
        call
      except CatchableError as e:
        if failure.isNil:
          failure = e

  if i == Reset:
    notify h.beforeReset
    self.kept.setLen 0
    for w in self.pending.mitems:
      if w[0] >= 0:
        w[0] = Skip
  elif i == Append:
    self.kept.add occ
    let i = self.kept.high
    notify h.added(i)
  elif i in self and self.kept[i] != occ:
    let old = move self.kept[i]
    self.kept[i] = occ
    case self.kept[i]
    of Present:
      notify h.changed(i, old)
    of Removed:
      notify h.removed(i, old)
  self.hooks.keepItIf(not it.isNil)

proc write(self: Space, i: int, occ: sink Occurence) =
  ## A write made from inside a hook callback is queued and applied after the
  ## current change has been notified to every hook. A hook that raises
  ## doesn't stop the others or the pending writes. The first failure is
  ## raised to the writer once everything has been applied.
  if self.notifying:
    self.pending.add (i, occ)
    return
  self.notifying = true
  var failure: ref CatchableError
  try:
    self.apply(i, occ, failure)
    var j = 0
    while j < self.pending.len:
      var w = move self.pending[j]
      inc j
      self.apply(w[0], move w[1], failure)
  finally:
    self.pending.setLen 0
    self.notifying = false
  if not failure.isNil:
    raise failure

proc `[]=`*(self: Space, i: int, n: sink Node) =
  guard i in self, "index out of bounds"
  self.write(i, Present(n: n))

proc add*(self: Space, n: sink Node) =
  self.write(Append, Present(n: n))

proc delete*(self: Space, i: int) =
  if i in self:
    self.write(i, Removed())

proc reset*(self: Space) =
  ## Hooks are notified while everything is still kept, then it is cleared.
  ## A write to a slot that was pending when the reset cleared it is dropped,
  ## even if a later add takes the same index.
  self.write(Reset, Removed())

method reified*(self: Space): Value =
  var
    kept = newSeq[Node]()
    hooks = newSeq[Node]()
  for i, each in self.kept:
    let i = Num(i)
    case each
    of Present(n):
      kept.add bl"($i present $n)"
    of Removed:
      kept.add bl"($i removed)"

  let snapshot = self.hooks
  for each in snapshot:
    if each.isNil:
      continue
    try:
      let h = toNode each.reified
      hooks.add bl"(hook $h)"
    except CatchableError:
      continue

  let (k, h) = (Set(kept), Set(hooks))

  toValue bl"(space $k $h)"

# ================
# Hook
# ================

proc space*(self: Hook): Space =
  self.space

proc detach(self: Hook) =
  let
    s = self.space
    j = s.hooks.find self
  if s.notifying:
    s.hooks[j] = nil
  else:
    s.hooks.delete j
  self.space = nil

# Setting the space from inside left or joined only records the target. The
# move in progress finishes first, then the loop moves again. A hook whose
# joined raises is detached again, so setting the space later calls joined
# afresh.
proc `space=`*(self: Hook, s: Space) =
  self.target = s
  if self.moving:
    return
  self.moving = true
  try:
    while self.space != self.target:
      let (old, next) = (self.space, self.target)
      if not old.isNil:
        self.detach
        self.left old
      self.space = next
      if not next.isNil:
        next.hooks.add self
        try:
          self.joined
        except CatchableError:
          self.detach
          self.target = nil
          raise
  finally:
    self.moving = false
