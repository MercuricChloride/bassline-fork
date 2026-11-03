## What happened to an image, as a log of entries kept in a file, each
## `(entry N {prior: P trigger: T at: MS session: S} EVENT)`. An event is
## one the kernel says (created, defined, changed, removed, layered,
## unlayered), `(evaluated FORM)`, `(refused FORM WORDS)` or `(undid N)`.
## Each event carries the state before and after it, so undoing needs no
## replay. P is the entry before, nil for the first, and T the entry whose
## evaluation or undoing caused this one, so a cause and its effects are
## one group. Undoing appends: `(undid N)` and the changes that reverse
## entry N and its group, last first. Nothing is erased.

import std/[os, times]
import core

refuseWith BasslineError

useValue Val

{.push raises: [BasslineError].}

var
  logPath: string
  sessionName: string
  log: seq[Val]
  triggers: seq[int]
  quiet: bool
  failure: string
  started: bool

let
  sPrior = headSym"prior"
  sTrigger = headSym"trigger"

proc numberOf*(entry: Val): int =
  ## an entry's N
  let n = entry.getChild(1)
  guard n.kind == bNum and n.num.isInt, "not an entry: " & $entry
  n.num.toInt

proc eventOf*(entry: Val): Val = entry.getChild(3)

proc triggerOf*(entry: Val): int =
  ## the entry that caused this one, 0 for none
  let t = entry.getChild(2).dict.getOr(sTrigger, nil)
  if not t.isNil and t.kind == bNum and t.num.isInt:
    result = t.num.toInt

proc entries*(): seq[Val] = log

proc lastEntry*(): int =
  if log.len > 0:
    result = log[^1].numberOf

proc entryAt(n: int): Val =
  for i in countdown(log.high, 0):
    if log[i].numberOf == n:
      return log[i]
  refuse "no entry " & $n

proc writeOut(entry: Val) {.raises: [].} =
  ## appends entry to the log's file, keeping what went wrong for later
  try:
    var f: File
    if not open(f, logPath, fmAppend):
      failure = "can't open " & logPath
      return
    try:
      f.write(entry.ce)
    finally:
      f.close()
  except CatchableError as e:
    failure = "can't write " & logPath & ": " & e.msg

proc append(event: Val): int =
  ## event as the log's next entry, in memory and in the file
  result = lastEntry() + 1
  let
    n = result
    prior = if n == 1: null else: Val.buildAtom($(n - 1), bNum, false)
    trigger = if triggers.len == 0 or triggers[^1] == 0: null
              else: Val.buildAtom($triggers[^1], bNum, false)
    at = int64(epochTime() * 1000)
    session = Val.buildAtom(sessionName, bText, false)
    entry = fromCE(bl"(entry $n {prior: $prior trigger: $trigger at: $at session: $session} $event)".ce)
  log.add entry
  writeOut entry

proc hear(event: Val) {.nimcall, raises: [].} =
  if quiet or not started:
    return
  try:
    discard append(event)
  except BasslineError as e:
    failure = e.msg

proc readLog*(path: string): seq[Val] =
  ## the entries the file at path holds, up to one a crash left torn
  var bytes: string
  try:
    bytes = readFile(path)
  except IOError as e:
    refuse "can't read " & path & ": " & e.msg
  var
    r: TypeReader[Val]
    pos = 0
  while pos < bytes.len and r.readCE(bytes, pos):
    result.add move r.value

proc startHistory*(path: string, session: string) =
  ## keeps what happens to the image in the log at path, carrying on its
  ## numbering, and as entries in memory
  try:
    if not fileExists(path):
      writeFile(path, "")
  except IOError as e:
    refuse "can't make " & path & ": " & e.msg
  logPath = path
  sessionName = session
  log = readLog(path)
  triggers = @[]
  failure = ""
  started = true
  if Listener(hear) notin image.listeners:
    image.listeners.add Listener(hear)

proc evaluating*(form: Val): int =
  ## logs `(evaluated FORM)`, whose number the events that follow take as
  ## their trigger until `evaluated`. Refuses when the log failed to write
  if failure.len > 0:
    let words = failure
    failure = ""
    refuse words
  if started:
    result = append(bl"(evaluated $form)")
  triggers.add result

proc evaluated*() =
  if triggers.len > 0:
    discard triggers.pop

proc refusedEval*(form: Val, words: string) =
  ## logs `(refused FORM WORDS)` within the evaluation, and ends it
  if started:
    let w = Val.buildAtom(words, bText, false)
    discard append(bl"(refused $form $w)")
  evaluated()

# ================
# Applying events
# ================

proc putSlotOrHeld(obj, name, v: Val) =
  ## a slot, or a Cell's held when name is `>>held`, now v, said as the
  ## kernel says it
  if name == sHeld:
    obj.put v
  else:
    obj.slotPut(name, v)

const kernelEvents = ["created", "defined", "changed", "removed", "layered", "unlayered"]

proc isKernelEvent(event: Val): bool =
  ## an event the kernel says of an object, `(KIND ID …)`
  event.kind == bRec and event.len >= 3 and event.getChild(0).kind == bSym and
    event.getChild(0).text in kernelEvents and event.getChild(1).kind == bBytes

proc read(event: Val): Val

proc apply(event: Val)

proc revive(obj: Val) =
  ## an object a snapshot left out, since nothing held it then, rebuilt
  ## from what the log says of it, so an undo or a replay can put it back
  if obj.layers.len > 1:
    return
  let id = obj.idOf
  for entry in log:
    let event = entry.eventOf
    if event.isKernelEvent and event.getChild(1) == id:
      event.read.apply

proc reviveIn(v: Val) =
  for each in v.walk:
    if each.isObject:
      each.revive

proc apply(event: Val) =
  ## event done again on the image, reviving the objects it names
  if not event.isKernelEvent:
    return
  for i in 2 ..< event.len:
    event.getChild(i).reviveIn
  let obj = event.getChild(1).placeholder
  case event.getChild(0).text
  of "created":
    if obj.layers.len <= 1:
      obj.fillObject(event.getChild(2))
  of "defined", "changed":
    obj.putSlotOrHeld(event.getChild(2), event.getChild(event.len - 1))
  of "removed":
    obj.slotRemove(event.getChild(2))
  of "layered":
    obj.putLayer(event.getChild(2))
  of "unlayered":
    obj.dropLayer(event.getChild(2).getChild(0))
  else: discard

proc read(event: Val): Val =
  ## event as written, its objects those of this image
  fromCE(event.ce).withObjects

proc replay*(log: seq[Val], after: int) =
  ## each event after entry `after` done again on the image, unlogged
  let was = quiet
  quiet = true
  try:
    for entry in log:
      if entry.numberOf > after:
        entry.eventOf.read.apply
  finally:
    quiet = was

proc invert(entry: Val, previous: Val) =
  ## entry's own event undone. previous is the entry before it, which put
  ## back the layer a `layered` replaced
  let event = entry.eventOf.read
  if not event.isKernelEvent:
    return
  for i in 2 ..< event.len:
    event.getChild(i).reviveIn
  let obj = event.getChild(1).placeholder
  case event.getChild(0).text
  of "changed":
    obj.putSlotOrHeld(event.getChild(2), event.getChild(3))
  of "defined":
    obj.slotRemove(event.getChild(2))
  of "removed":
    obj.slotPut(event.getChild(2), event.getChild(3))
  of "layered":
    let form = event.getChild(2)
    obj.dropLayer(form.getChild(0))
    if not previous.isNil and previous.triggerOf == entry.triggerOf:
      let before = previous.eventOf.read
      if before.kind == bRec and before.len == 3 and before.getChild(0) == headSym"unlayered" and
          before.getChild(1) == event.getChild(1) and
          before.getChild(2).getChild(0) == form.getChild(0):
        obj.putLayer(before.getChild(2))
  of "unlayered":
    obj.putLayer(event.getChild(2))
  else: discard

proc undo*(n: int) =
  ## entry n and every entry it caused, undone last first, after logging
  ## `(undid N)`, which the changes that undo them take as their trigger
  guard started, "no history to undo"
  discard entryAt(n)
  var caused: Table[int, seq[int]]
  for entry in log:
    let t = entry.triggerOf
    if t > 0:
      caused.mgetOrPut(t, @[]).add entry.numberOf
  var
    order: seq[int]
    todo = @[(n, false)]
  while todo.len > 0:
    let (at, expanded) = todo.pop
    if expanded:
      order.add at
    else:
      todo.add (at, true)
      for child in caused.getOrDefault(at):
        todo.add (child, false)
  let undid = append(bl"(undid $n)")
  triggers.add undid
  try:
    for at in order:
      let entry = entryAt(at)
      let previous = if at > 1: (try: entryAt(at - 1) except BasslineError: nil) else: nil
      entry.invert(previous)
  finally:
    discard triggers.pop

# ================
# Natives
# ================

proc intArg(v, msg: Val): int =
  guard v.kind == bNum and v.num.isInt, "not an entry number: " & $v & " in " & $msg
  v.num.toInt

proc undoN(msg, self, sender: Val): Val {.native: "undo".} =
  ## (undo N)
  ## Undoes log entry N and every entry it caused, last first, by appending
  ## (undid N) and the changes that reverse them. Nothing is erased, so
  ## undoing an (undid N) does it again. Answers the (undid N) entry's number.
  let a = msg.args(sender)
  guard a.len == 1, "(undo N): " & $msg
  undo(a[0].intArg(msg))
  Val.buildAtom($lastEntry(), bNum, false)

proc historyN(msg, self, sender: Val): Val {.native: "history".} =
  ## (history OBJ NAME?)
  ## The log entries that touch OBJ, or only its slot NAME, oldest first.
  let a = msg.args(sender)
  guard a.len in 1 .. 2, "(history OBJ NAME?): " & $msg
  let id = a[0].idOf
  guard not id.isNil, "not an object in the image: " & $a[0]
  var found: seq[Val]
  for entry in log:
    let event = entry.eventOf
    if event.kind == bRec and event.len >= 2 and event.getChild(1) == id:
      if a.len == 1 or (event.len >= 3 and event.getChild(2) == a[1]):
        found.add entry
  Val.buildFrame(found, bList, false)

proc entriesN(msg, self, sender: Val): Val {.native: "entries".} =
  ## (entries FROM? TO?)
  ## The log's entries numbered FROM through TO, all of them by default.
  let a = msg.args(sender)
  guard a.len <= 2, "(entries FROM? TO?): " & $msg
  let
    lo = if a.len >= 1: a[0].intArg(msg) else: 1
    hi = if a.len == 2: a[1].intArg(msg) else: lastEntry()
  var found: seq[Val]
  for entry in log:
    if entry.numberOf in lo .. hi:
      found.add entry
  Val.buildFrame(found, bList, false)

proc entryN(msg, self, sender: Val): Val {.native: "entry".} =
  ## (entry N)
  ## The log's entry N.
  let a = msg.args(sender)
  guard a.len == 1, "(entry N): " & $msg
  entryAt(a[0].intArg(msg))

{.pop.}
