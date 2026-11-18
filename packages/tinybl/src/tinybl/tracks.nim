from std/sequtils import keepItIf
import std/deques
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

  ResetProc* = proc(kept: var seq[Entry])

  Op = object
    case
    of Add:
      addNode: Node
    of Update:
      updateIndex: int
      updateNode: Node
    of Delete:
      deleteIndex: int
    of Reset:
      resetCb: ResetProc

  Track* = ref object of Live
    kept: seq[Entry]
    monitors: seq[Monitor]
    notifying: bool
    pending: Deque[Op]

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

method added*(self: Monitor, i: int, entry: Entry) {.base.} =
  discard

method changed*(self: Monitor, i: int, prev, curr: Entry) {.base.} =
  discard

method removed*(self: Monitor, i: int, entry: Entry) {.base.} =
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

proc `[]`*(self: Track, i: BackwardsIndex): lent Entry =
  return self.kept[i]

proc `[]`*(self: Track, i: Slice[int]): seq[Entry] =
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

func holds(self: Track, i: int, n: Node): bool =
  case self.kept[i]
  of Present(m): m == n
  of Removed: false

func namesSlot(op: Op): bool =
  case op
  of Update, Delete: true
  of Add, Reset: false

proc expected(self: Track, op: Op): bool =
  ## What `op` would answer if it were applied now.
  case op
  of Add(n): self.keeps(n)
  of Update(i, n): self.holds(i, n) or self.keeps(n)
  of Delete, Reset: true

proc apply(self: Track, op: sink Op, failure: var ref CatchableError): bool =
  ## Answers whether what the op put is on the track afterwards.
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

  template asks(n: Node): bool =
    var kept = false
    attempt:
      kept = self.keeps(n)
    kept

  case op
  of Add(n):
    if asks(n):
      self.kept.add Present(n: move n)
      let i = self.kept.high
      notify h.added(i, self.kept[i])
      result = true
  of Update(i, n):
    if self.holds(i, n):
      result = true
    elif asks(n):
      let prev = move self.kept[i]
      self.kept[i] = Present(n: move n)
      notify h.changed(i, prev, self.kept[i])
      result = true
  of Delete(i):
    if self.kept[i] != Removed():
      let entry = move self.kept[i]
      self.kept[i] = Removed()
      notify h.removed(i, entry)
  of Reset(cb):
    notify h.beforeReset
    let run = cb
    attempt:
      run(self.kept)
    var rest = initDeque[Op]()
    while self.pending.len > 0:
      var waiting = self.pending.popFirst
      if not waiting.namesSlot:
        rest.addLast waiting
    self.pending = rest
    notify h.afterReset
  self.monitors.keepItIf(not it.isNil)

proc write(self: Track, op: sink Op): bool =
  ## A write made from inside a monitor callback is queued and applied after
  ## the current change has been notified to every monitor. A monitor that
  ## raises doesn't stop the others or the pending writes. The first failure
  ## is raised to the writer once everything has been applied.
  ##
  ## Answers whether what the op put is on the track. A write applied now
  ## answers exactly. A queued one answers what `keeps` says now, and `keeps`
  ## decides again when it is applied.
  if self.notifying:
    result = self.expected(op)
    self.pending.addLast op
    return
  self.notifying = true
  var failure: ref CatchableError
  try:
    result = self.apply(op, failure)
    while self.pending.len > 0:
      discard self.apply(self.pending.popFirst, failure)
  finally:
    self.pending.clear
    self.notifying = false
  if not failure.isNil:
    raise failure

proc add*(self: Track, n: sink Node): bool {.discardable.} =
  ## Whether the track kept `n`.
  self.write Add(addNode: n)

proc update*(self: Track, i: int, n: sink Node): bool {.discardable.} =
  ## Whether slot `i` now holds `n`.
  guard i in self, "index out of bounds"
  self.write Update(updateIndex: i, updateNode: n)

proc `[]=`*(self: Track, i: int, n: sink Node) =
  discard self.update(i, n)

proc delete*(self: Track, i: int) =
  if i in self:
    discard self.write Delete(deleteIndex: i)

proc reset*(self: Track, cb: ResetProc) =
  ## Replaces what is kept in one step: `cb` changes the slots in place, to
  ## compact, truncate or replace them, and what it puts there is not asked
  ## of `keeps`. Monitors are notified before it runs, with everything as it
  ## was, and after, with everything as it now is. A write to a slot that was
  ## pending when the reset ran is dropped, since its index may now name
  ## something else.
  ##
  ## `cb` should not raise partway through an edit. If it does, monitors are
  ## still notified after, with whatever it left, and the failure is raised
  ## to the writer.
  guard not cb.isNil, "cb cannot be nil"
  discard self.write Reset(resetCb: cb)

proc reset*(self: Track, entries: sink seq[Entry]) =
  self.reset(
    proc(e: var seq[Entry]) =
      e = move entries)

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

proc clear*(self: Track) =
  let snapshot = self.monitors
  for each in snapshot:
    if not each.isNil and each.track == self:
      `track=`(each, nil)
  self.reset @[]
