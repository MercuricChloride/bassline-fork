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
    track, target: Track
    moving: bool

  ResetProc* = proc(kept: var seq[Entry])
  EditProc* = proc(n: var Node)

  Op = object
    case
    of Add:
      addNode: Node
    of Update:
      updateIndex: int
      updateNode: Node
    of Delete:
      deleteIndex: int
    of Edit:
      editIndex: int
      editProc: EditProc
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

# A track hears its own writes through these, before any monitor does, so a
# subclass can keep what `keeps` and its own queries read.

method added*(self: Track, i: int, entry: Entry) {.base.} =
  discard

method changed*(self: Track, i: int, prev, curr: Entry) {.base.} =
  discard

method removed*(self: Track, i: int, entry: Entry) {.base.} =
  discard

method beforeReset*(self: Track) {.base.} =
  discard

method afterReset*(self: Track) {.base.} =
  discard

func holds(self: Track, i: int, n: Node): bool =
  case self.kept[i]
  of Present(m): m == n
  of Removed: false

func namesSlot(op: Op): bool =
  case op
  of Update, Delete, Edit: true
  of Add, Reset: false

proc expected(self: Track, op: Op): bool =
  ## What `op` would answer if it were applied now.
  case op
  of Add(n): self.keeps(n)
  of Update(i, n): self.holds(i, n) or self.keeps(n)
  of Delete, Edit, Reset: true

proc apply(self: Track, op: sink Op, failure: var ref CatchableError): bool =
  ## Answers whether what the op put is on the track afterwards.
  template attempt(body: untyped) =
    try:
      body
    except CatchableError as e:
      if failure.isNil:
        failure = e

  template notify(call: untyped) =
    block:
      let h {.inject.} = self
      attempt:
        call
    for h {.inject.} in self.attached:
      attempt:
        call

  template asks(n: Node): bool =
    var kept = false
    attempt:
      kept = self.keeps(n)
    kept

  template replace(at, node: untyped) =
    if self.holds(at, node):
      result = true
    elif asks(node):
      let prev = move self.kept[at]
      self.kept[at] = Present(n: move node)
      notify h.changed(at, prev, self.kept[at])
      result = true

  case op
  of Add(n):
    if asks(n):
      self.kept.add Present(n: move n)
      let i = self.kept.high
      notify h.added(i, self.kept[i])
      result = true
  of Update(i, n):
    replace(i, n)
  of Delete(i):
    if self.kept[i] != Removed():
      let entry = move self.kept[i]
      self.kept[i] = Removed()
      notify h.removed(i, entry)
  of Edit(i, edit):
    case self.kept[i]
    of Removed: discard
    of Present(current):
      var draft = current
      let run = edit
      attempt:
        run(draft)
        replace(i, draft)
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
  ## Replaces whatever slot `i` holds with `n`, so the last replace wins. A
  ## change that depends on what the slot holds, such as binding part of the
  ## node, belongs in the edit form.
  ##
  ## Whether slot `i` now holds `n`.
  guard i in self, "index out of bounds"
  self.write Update(updateIndex: i, updateNode: n)

proc update*(self: Track, i: int, edit: EditProc) =
  ## Edits a copy of the node in slot `i`, at this write's turn, so `edit`
  ## sees the node as earlier writes left it, then puts the copy in the slot
  ## as the replace form would. If `edit` raises, or `keeps` refuses what it
  ## made, the slot is untouched. An edit that changes nothing notifies no
  ## one. A removed slot is left alone.
  ##
  ## Only the node's structure is copied. A live object already in the node
  ## is shared with the copy, so `edit` should put a new one in place and
  ## not change one that is there.
  guard i in self, "index out of bounds"
  guard not edit.isNil, "edit cannot be nil"
  discard self.write Edit(editIndex: i, editProc: edit)

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
  for each in self.kept:
    case each
    of Present(n):
      kept.add bl"(present $n)"
    of Removed:
      kept.add bl"(removed)"

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
