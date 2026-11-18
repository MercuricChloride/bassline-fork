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
    notifying, revising: bool

  Swap* = object
    idx*: int
    entry*: Entry

  ReviseProc* = proc(draft: var Draft)

  Draft* = object
    kept: seq[Entry]
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
  self.kept.len

proc `[]`*(self: Draft, i: int): lent Entry =
  guard i in 0..<self.len, "index out of bounds"
  for i in 0..<self.swaps.len:
    if self.swaps[i].idx == i:
      return self.swaps[i].entry
  return self.kept[i]

proc stage(self: var Draft, i: int, entry: sink Entry) =
  guard i in 0..<self.len, "index out of bounds"
  for s in self.swaps.mitems:
    if s.idx == i:
      if s.entry != entry:
        s.entry = entry
      return
  if entry != self.kept[i]:
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

iterator attached(self: Track): Monitor =
  ## The monitors attached when the loop starts, minus any detached since. A
  ## monitor detached during a notification has its slot set to nil, and one
  ## attached during it is past the end, so neither is called for that change.
  let n = self.monitors.len
  for j in 0 ..< n:
    let h = self.monitors[j]
    if not h.isNil:
      yield h

# A track hears its own writes through these, before any monitor does, so a
# subclass can keep what `keeps` and its own queries read.

method keeps*(self: Track, n: Node): bool {.base.} =
  ## Whether the track holds on to `n` when it is added or put in a slot. It
  ## may be asked more than once about the same write.
  true

method added*(self: Track, i: int, entry: Entry) {.base.} =
  discard

method revised*(self: Track, swaps: openArray[Swap]) {.base.} =
  discard

proc rollback(self: var Draft, entries: var seq[Entry]) =
  entries = move self.kept

proc commit(self: var Draft, entries: var seq[Entry]) =
  entries = move self.kept
  for s in self.swaps.mitems:
    entries[s.idx].swap(s.entry)

proc add*(self: Track, n: sink Node): Contribution {.discardable.}

proc revise*(self: Track, cb: ReviseProc): bool {.discardable.} =
  guard not isNil(cb), "cb cannot be nil"
  guard not self.revising, "cannot revise mid-revision"
  guard not self.notifying, "cannot revise mid-notification"
  self.revising = true
  var
    err: ref CatchableError
    draft = Draft(kept: move self.kept)
  try:
    cb(draft)
  except CatchableError as e:
    err = e
  draft.swaps.keepItIf(draft.kept[it.idx] != it.entry)
  if err.isNil:
    # draft.commit swaps the new & old entries on the draft
    draft.commit(self.kept)
    if draft.swaps.len == 0:
      return
    # so from here draft.swaps contains the old entries
    try:
      self.revised(draft.swaps)
    except CatchableError:
      discard
    for m in self.attached:
      try:
        m.revised(draft.swaps)
      except CatchableError:
        # NOTE: This probably isn't correct to discard this error
        # but I also don't want to rollback here?
        # tsk tsk
        discard
    self.revising = false
    while self.staged.len > 0:
      self.add self.staged.popFirst
  else:
    draft.rollback(self.kept)
    # NOTE for now we are going to discard staged additions
    # if we hit an error during the revision cb
    self.staged.clear
    self.revising = false
    raise err

template reviseIt*(self: Track, body: untyped): untyped =
  self.revise(proc(it {.inject.}: var Draft) = body)

proc add*(self: Track, n: sink Node): Contribution {.discardable.} =
  ## Whether the track kept `n`.
  if not self.keeps(n):
    return Contribution.Ignored

  if self.revising:
    self.staged.addLast n
    return Contribution.Staged

  self.notifying = true
  result = Contribution.Kept
  self.kept.add Present(n: n)
  let i = self.kept.high
  var err: ref CatchableError
  try:
    self.added(i, self.kept[i])
  except CatchableError as e:
    if err.isNil:
      err = e
  for m in self.attached:
    try:
      m.added(i, self.kept[i])
    except CatchableError as e:
      if err.isNil:
        err = e
  self.notifying = false
  self.monitors.keepItIf(not it.isNil)
  if not err.isNil:
    raise err

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
  if s.notifying:
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
