from std/sequtils import keepItIf
import std/deques
import ./[micro, micro_macros]

refuseWith BasslineError

type
  Contribution* {.pure.} = enum
    Ignored, Staged, Kept

  Monitor* = ref object of Live
    sourceTrack, targetTrack: Track
    moving: bool

  Entry* = object
    case
    of Absent: discard
    of Present:
      n*: Node

  Track* = ref object of Live
    kept: seq[Entry]
    staged: Deque[Node]
    monitors: seq[Monitor]
    writing: bool

  Swap* = object
    idx*: int
    entry*: Entry

  ReviseProc* = proc(draft: var Draft)

  Draft* = object
    source: Track
    swaps: seq[Swap]

func `==`*(a, b: Entry): bool =
  case a
  of Absent:
    case b
    of Absent: true
    of Present: false
  of Present(x):
    case b
    of Absent: false
    of Present(y): x == y

proc len*(self: Draft): int =
  if self.source.isNil: 0 else: self.source.kept.len

proc `[]`*(self: Draft, i: int): lent Entry =
  guard i in 0..<self.len, "index out of bounds"
  for s in self.swaps:
    if s.idx == i:
      return s.entry
  return self.source.kept[i]

proc stage(self: var Draft, i: int, entry: sink Entry) =
  guard i in 0..<self.len, "index out of bounds"
  for s in self.swaps.mitems:
    if s.idx == i:
      s.entry = entry
      return
  if entry != self.source.kept[i]:
    self.swaps.add Swap(idx: i, entry: entry)

proc `[]=`*(self: var Draft, i: int, n: sink Node) =
  self.stage(i, Present(n: n))

proc delete*(self: var Draft, i: int) =
  self.stage(i, Absent())

method added*(self: Monitor, i: int, entry: Entry) {.base.} =
  discard

method revised*(self: Monitor, swaps: openArray[Swap]) {.base.} =
  discard

method joined*(self: Monitor) {.base.} =
  discard

method left*(self: Monitor, s: Track) {.base.} =
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

iterator attached*(self: Track): Monitor =
  let ms = self.monitors
  for m in ms:
    if not isNil(m):
      yield m

# A track hears its own writes through these, before any monitor does, so a
# subclass can keep what `keeps` and its own queries read.

method keeps*(self: Track, n: Node): bool {.base.} =
  ## Called when an addition reaches the front of this track's queue.
  true

method added*(self: Track, i: int, entry: Entry) {.base.} =
  discard

method revised*(self: Track, swaps: openArray[Swap]) {.base.} =
  discard

template capture(err: var ref CatchableError, body: untyped) =
  try:
    body
  except CatchableError as e:
    if err.isNil: err = e

template notify(self: Track, err: var ref CatchableError,
                hook: untyped, args: varargs[untyped]) =
  capture(err):
    hook(self, args)
  # A monitor can detach during delivery. Its slot stays vacant until the
  # turn ends, and monitors attached by another monitor wait for the next change.
  let count = self.monitors.len
  for i in 0..<count:
    let monitor = self.monitors[i]
    if not monitor.isNil:
      capture(err):
        hook(monitor, args)

proc admit(self: Track, n: sink Node, err: var ref CatchableError): Contribution =
  var keep = false
  capture(err):
    keep = self.keeps(n)
  if not keep:
    return Contribution.Ignored

  self.kept.add Present(n: move n)
  let i = self.kept.high
  self.notify(err, added, i, self.kept[i])
  Contribution.Kept

template writeTurn(self: Track, err, body: untyped) =
  var err: ref CatchableError
  self.writing = true
  try:
    body
    while self.staged.len > 0:
      discard self.admit(self.staged.popFirst(), err)
  finally:
    self.writing = false
    self.staged.clear()
    self.monitors.keepItIf(not it.isNil)
  if not err.isNil: raise err

proc add*(self: Track, n: sink Node): Contribution {.discardable.} =
  ## Adds a node to the track, or stages the node for writing
  ## if this is called while we are writing
  if self.writing:
    self.staged.addLast n
    return Contribution.Staged
  else:
    self.writeTurn(err):
      result = self.admit(n, err)

proc revise*(self: Track, cb: ReviseProc) =
  ## The callback edits a draft over the committed slots. If it raises, its
  ## edits not applied and the staged adds are discarded.
  guard not cb.isNil, "cb cannot be nil"
  guard not self.writing, "cannot revise during another write"
  self.writeTurn(err):
    var draft = Draft(source: self)
    cb(draft)
    draft.swaps.keepItIf(self.kept[it.idx] != it.entry)
    for s in draft.swaps.mitems:
      swap(self.kept[s.idx], s.entry)
    if draft.swaps.len > 0:
      self.notify(err, revised, draft.swaps)

template reviseIt*(self: Track, body: untyped): untyped =
  self.revise(proc(it {.inject.}: var Draft) = body)

method reified*(self: Track): Value =
  var
    kept = newSeq[Node]()
    monitors = newSeq[Node]()
  for each in self.kept:
    case each
    of Present(n):
      kept.add bl"(present $n)"
    of Absent:
      kept.add bl"Absent"

  let snapshot = self.monitors
  for each in snapshot:
    if each.isNil:
      continue
    try:
      monitors.add toNode each.reified
    except CatchableError:
      continue

  let (k, h) = (List(kept), List(monitors))

  toValue bl"!(track $k $h)"

# ================
# Monitor
# ================

proc track*(self: Monitor): Track =
  self.sourceTrack

proc detach(self: Monitor) =
  let
    s = self.sourceTrack
    j = s.monitors.find self
  if s.writing:
    s.monitors[j] = nil
  else:
    s.monitors.delete j
  self.sourceTrack = nil

# Setting the track from inside left or joined only records the target. The
# move in progress finishes first, then the loop moves again. A monitor whose
# joined raises is detached again, so setting the track later calls joined
# afresh.
proc `track=`*(self: Monitor, s: Track) =
  self.targetTrack = s
  if self.moving:
    return
  self.moving = true
  try:
    while self.sourceTrack != self.targetTrack:
      let (old, next) = (self.sourceTrack, self.targetTrack)
      if not old.isNil:
        self.detach
        self.left old
      self.sourceTrack = next
      if not next.isNil:
        next.monitors.add self
        try:
          self.joined
        except CatchableError:
          self.detach
          self.targetTrack = nil
          raise
  finally:
    self.moving = false

proc up*(self: Track, monitors: varargs[Monitor]) =
  for m in monitors:
    m.track = self

proc down*(self: Track, monitors: varargs[Monitor]) =
  for m in monitors:
    if m.track == self:
      m.track = nil
