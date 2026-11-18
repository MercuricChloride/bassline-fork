from std/sequtils import keepItIf
import ./[micro, micro_macros]

refuseWith BasslineError

type
  Entry* = object
    case
    of Removed: discard
    of Present:
      n*: Node

  Monitor* = ref object of Live
    track: Track
    target: Track
    moving: bool

  ResetProc* = proc(kept: var seq[Entry]) {.raises: [].}

  Track* = ref object of Live
    kept: seq[Entry]
    monitors: seq[Monitor]
    notifying: bool
    pending: seq[(int, Entry, ResetProc)]

const
  AppendIndex = -1
  ResetIndex = -2
  SkipIndex = -3

func `==`*(a, b: Entry): bool =
  case a
  of Removed:
    case b
    of Removed: true
    of Present: false
  of Present(x):
    case b
    of Removed: false
    of Present(y): x == y

method added*(self: Monitor, i: int) {.base.} =
  discard

method changed*(self: Monitor, i: int, old: Entry) {.base.} =
  discard

method removed*(self: Monitor, i: int, old: Entry) {.base.} =
  discard

method joined*(self: Monitor) {.base.} =
  discard

method left*(self: Monitor, s: Track) {.base.} =
  discard

method beforeReset*(self: Monitor) {.base.} =
  discard

method afterReset*(self: Monitor) {.base.} =
  discard

# ================
# Track
# ================

proc len*(self: Track): int =
  self.kept.len

proc contains*(self: Track, i: int): bool =
  i in 0..<self.len

proc `[]`*(self: Track, i: int): lent Entry =
  return self.kept[i]

iterator attached(self: Track): Monitor =
  ## The monitors attached when the loop starts, minus any detached since. A
  ## monitor detached during a notification has its slot set to nil, and one
  ## attached during it is past the end, so neither is called for that change.
  let n = self.monitors.len
  for j in 0 ..< n:
    let h = self.monitors[j]
    if not h.isNil:
      yield h

method keeps*(self: Track, n: Node): bool {.base.} =
  ## Whether the track holds on to `n` when it is added or put in a slot. It
  ## may be asked more than once about the same write.
  true

proc apply(self: Track, i: int, entry: sink Entry, cb: ResetProc,
           failure: var ref CatchableError): bool =
  ## Answers whether the entry is on the track afterwards.
  template attempt(body: untyped) =
    try:
      body
    except CatchableError as e:
      if failure.isNil:
        failure = e

  template notify(call: untyped) =
    for h {.inject.} in self.attached:
      attempt:
        call

  let same = i in self and self.kept[i] == entry
  var held = true
  if not same:
    case entry
    of Present(n):
      held = false
      attempt:
        held = self.keeps(n)
    of Removed: discard

  if i == ResetIndex:
    notify h.beforeReset
    cb(self.kept)
    for w in self.pending.mitems:
      if w[0] >= 0:
        w[0] = SkipIndex
    notify h.afterReset
  elif same or not held:
    discard
  elif i == AppendIndex:
    self.kept.add entry
    let i = self.kept.high
    notify h.added(i)
  elif i notin self:
    held = false
  else:
    let old = move self.kept[i]
    self.kept[i] = entry
    case self.kept[i]
    of Present:
      notify h.changed(i, old)
    of Removed:
      notify h.removed(i, old)
  self.monitors.keepItIf(not it.isNil)
  held

proc write(self: Track, i: int, entry: sink Entry, cb: ResetProc = nil): bool =
  ## A write made from inside a monitor callback is queued and applied after
  ## the current change has been notified to every monitor. A monitor that
  ## raises doesn't stop the others or the pending writes. The first failure
  ## is raised to the writer once everything has been applied.
  ##
  ## Answers whether the entry is on the track. A write applied now answers
  ## exactly. A queued one answers what `keeps` says now, and `keeps` decides
  ## again when it is applied.
  if self.notifying:
    result = true
    if i notin self or self.kept[i] != entry:
      case entry
      of Present(n):
        result = self.keeps(n)
      of Removed: discard
    self.pending.add (i, entry, cb)
    return
  self.notifying = true
  var failure: ref CatchableError
  try:
    result = self.apply(i, entry, cb, failure)
    var j = 0
    while j < self.pending.len:
      var w = move self.pending[j]
      inc j
      discard self.apply(w[0], move w[1], w[2], failure)
  finally:
    self.pending.setLen 0
    self.notifying = false
  if not failure.isNil:
    raise failure

proc add*(self: Track, n: sink Node): bool {.discardable.} =
  ## Whether the track kept `n`.
  self.write(AppendIndex, Present(n: n))

proc update*(self: Track, i: int, n: sink Node): bool {.discardable.} =
  ## Whether slot `i` now holds `n`.
  guard i in self, "index out of bounds"
  self.write(i, Present(n: n))

proc `[]=`*(self: Track, i: int, n: sink Node) =
  discard self.update(i, n)

proc delete*(self: Track, i: int) =
  if i in self:
    discard self.write(i, Removed())

proc reset*(self: Track, cb: ResetProc) =
  ## Replaces what is kept in one step: `cb` changes the slots in place, to
  ## compact, truncate or replace them, and what it puts there is not asked
  ## of `keeps`. Monitors are notified before it runs, with everything as it
  ## was, and after, with everything as it now is. A write to a slot that was
  ## pending when the reset ran is dropped, since its index may now name
  ## something else.
  guard not cb.isNil, "cb cannot be nil"
  discard self.write(ResetIndex, Removed(), cb)

method reified*(self: Track): Value =
  var
    kept = newSeq[Node]()
    monitors = newSeq[Node]()
  for i, each in self.kept:
    let i = Num(i)
    case each
    of Present(n):
      kept.add bl"($i present $n)"
    of Removed:
      kept.add bl"($i removed)"

  let snapshot = self.monitors
  for each in snapshot:
    if each.isNil:
      continue
    try:
      let h = toNode each.reified
      monitors.add bl"(monitor $h)"
    except CatchableError:
      continue

  let (k, h) = (Set(kept), Set(monitors))

  toValue bl"(track $k $h)"

# ================
# Monitor
# ================

proc track*(self: Monitor): Track =
  self.track

proc detach(self: Monitor) =
  let
    s = self.track
    j = s.monitors.find self
  if s.notifying:
    s.monitors[j] = nil
  else:
    s.monitors.delete j
  self.track = nil

# Setting the track from inside left or joined only records the target. The
# move in progress finishes first, then the loop moves again. A monitor whose
# joined raises is detached again, so setting the track later calls joined
# afresh.
proc `track=`*(self: Monitor, s: Track) =
  self.target = s
  if self.moving:
    return
  self.moving = true
  try:
    while self.track != self.target:
      let (old, next) = (self.track, self.target)
      if not old.isNil:
        self.detach
        self.left old
      self.track = next
      if not next.isNil:
        next.monitors.add self
        try:
          self.joined
        except CatchableError:
          self.detach
          self.target = nil
          raise
  finally:
    self.moving = false
