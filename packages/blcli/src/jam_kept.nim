## The jams kept on this machine, each a log in ~/.bl/jams, NAME.blb:
## `bl jam serve --as NAME` serves one, `--new` begins one, and
## `bl jam list` says what each holds. A jam being served holds its log
## locked, so it is served once, and while it is, says where beside it,
## in NAME.at. Each jam served, kept or not, and each bridge also says
## it is running in ~/.bl/running, so `bl jam running` lists them and
## `bl jam stop` stops them.

import std/[algorithm, options, os, posix, sequtils, strutils]
import harness
import bl/[core, queries]
import bl/lib/[bvarfile, jam]

var
  LOCK_SH {.importc, header: "<sys/file.h>".}: cint
  LOCK_EX {.importc, header: "<sys/file.h>".}: cint
  LOCK_NB {.importc, header: "<sys/file.h>".}: cint

proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}

proc jamsDir*(): string =
  ## where the jams kept on this machine are
  getHomeDir() / ".bl" / "jams"

proc keptAt*(name: string): string =
  ## where the jam called `name` is kept
  jamsDir() / name & ".blb"

proc fileName*(name: string): bool =
  ## whether `name` can name a file of its own: letters, digits, `.`,
  ## `_` and `-`, and not beginning with `.`
  name.len > 0 and name[0] != '.' and
    name.allCharsInSet(Letters + Digits + {'.', '_', '-'})

proc placeFile(log: string): string =
  log.changeFileExt("at")

proc hold*(log: string): bool =
  ## locks the log at `log`, made if it isn't there, for as long as this
  ## process runs, answering whether another held it already
  let fd = posix.open(log.cstring, O_WRONLY or O_CREAT or O_APPEND,
                      S_IRUSR or S_IWUSR or S_IRGRP or S_IROTH)
  if fd < 0: fail "can't keep the jam in " & log & ": " & $strerror(errno)
  if flock(fd, LOCK_EX or LOCK_NB) != 0:
    let err = errno
    discard posix.close(fd)
    if err == EWOULDBLOCK: return false
    chatter "can't lock " & log & " (" & $strerror(err) & "); serving it unlocked"
    return true
  discard tryRemoveFile(placeFile(log))   # where it was served before
  true                                    # the lock lasts as long as fd

proc served*(log, place: string) =
  ## says where the jam kept at `log`, held, is being served
  discard writeValue(placeFile(log), text(place))

proc servedAt*(log: string): Option[Value] =
  ## where the jam kept at `log` is being served, if it is, or nil if it
  ## hasn't said where yet
  let fd = posix.open(log.cstring, O_RDONLY)
  if fd < 0: return none(Value)
  defer: discard posix.close(fd)
  if flock(fd, LOCK_SH or LOCK_NB) == 0 or errno != EWOULDBLOCK: return none(Value)
  try: some valueIn(placeFile(log))
  except CatchableError: some null()

proc named(id: Value): Value =
  ## the first of an ID's names that is a symbol or text
  for n in identities(id):
    if n.kind in {bSym, bText}: return n
  id

proc listing*(name, log: string): Value =
  ## what `bl jam list` says of the jam kept at `log`: (jam NAME
  ## {kept: PATH records: N rooms: {ROOM …} who: {NAME …} began: MS
  ## last: MS served: PLACE}), served only while it is, and began and
  ## last from every `at` its answers carry
  let records = valuesIn(log, mend = false)
  var
    rooms, who = initSet()
    began, last = none(int)
  for r in records:
    let h = heard(r)
    if h.isNone: continue
    let said = h.get.said
    if h.get.q == RoomsQ: rooms.incl said
    if not said.isObject: continue
    if h.get.q == HereQ:
      for by in said.answers(ByQ): who.incl named(by)
    for at in said.answers(AtQ):
      if at.isKind(bNum) and at.num.isInt:
        let ms = at.num.toInt
        if began.isNone or ms < began.get: began = some ms
        if last.isNone or ms > last.get: last = some ms
  var entries = @[(sym"kept", text(log)), (sym"records", toValue(records.len)),
                  (sym"rooms", rooms), (sym"who", who)]
  if began.isSome: entries.add (sym"began", toValue(began.get))
  if last.isSome: entries.add (sym"last", toValue(last.get))
  let at = servedAt(log)
  if at.isSome: entries.add (sym"served", at.get)
  initRec(@[JamQ, sym(name), initDict(entries)])

proc list*(t: Tool, a: Args) =
  if a.positional.len > 0:
    t.misuse "takes no arguments"
  var names: seq[string]
  for kind, path in walkDir(jamsDir()):
    let (_, name, ext) = path.splitFile
    if kind in {pcFile, pcLinkToFile} and ext == ".blb" and fileName(name):
      names.add name
  if names.len == 0:
    chatter "no jams kept in " & jamsDir() & " yet; bl jam serve --new begins one"
  for name in names.sorted:
    try: emit listing(name, keptAt(name))
    except CatchableError as e: chatter "passing over " & keptAt(name) & ": " & e.msg

# ================ what is running here ================

proc runningDir*(): string =
  ## where each jam served on this machine, and each bridge, says it is
  ## running: a file each, PID.blb, held locked while it runs
  getHomeDir() / ".bl" / "running"

proc held(path: string): bool =
  ## whether a process holds the file at `path` locked
  let fd = posix.open(path.cstring, O_RDONLY)
  if fd < 0: return false
  defer: discard posix.close(fd)
  flock(fd, LOCK_SH or LOCK_NB) != 0 and errno == EWOULDBLOCK

proc running*(what: Value) =
  ## says, for as long as this process runs, that it is running and what
  ## it is: `what`, kept in runningDir() under its pid. It is written and
  ## locked under another name first, so no reader finds it unheld
  let path = runningDir() / ($getCurrentProcessId() & ".blb")
  try: createDir(runningDir())
  except OSError: return
  let fd = posix.open(cstring(path & ".new"), O_WRONLY or O_CREAT or O_TRUNC,
                      S_IRUSR or S_IWUSR)
  if fd < 0: return
  let bytes = what.ce.toString
  if flock(fd, LOCK_EX or LOCK_NB) != 0 or
     posix.write(fd, unsafeAddr bytes[0], bytes.len) != bytes.len:
    discard posix.close(fd)
    return
  moveFile(path & ".new", path)   # the lock lasts as long as fd

proc runningHere*(): seq[tuple[pid: int, what: Value]] =
  ## what is running on this machine, by pid. A file nothing holds was
  ## left by a process that has gone, and is taken away
  for kind, path in walkDir(runningDir()):
    let (_, name, ext) = path.splitFile
    if kind != pcFile or ext != ".blb" or name.len == 0 or not name.allCharsInSet(Digits):
      continue
    if not held(path):
      discard tryRemoveFile(path)
      continue
    try: result.add (parseInt(name), valueIn(path))
    except CatchableError: discard
  result.sort((a, b) => cmp(a.pid, b.pid))

proc said(what: Value, q: string): Option[Value] =
  ## what a running record says under `q`
  if what.isKind(bRec) and what.items.len > 0 and what.items[^1].isKind(bDict):
    let d = what.items[^1]
    if sym(q) in d.dict: return some d[sym(q)]
  none(Value)

proc describe(pid: int, what: Value): string =
  ## a line for something running
  let served = said(what, "served")
  let ends = said(what, "ends")
  if what.head == sym"bridge" and ends.isSome:
    "the bridge between " & ends.get.items.data.mapIt(it.text).join(" and ") &
      " (pid " & $pid & ")"
  elif what.head == JamQ and what.items.len == 3:
    "jam " & what.items[1].text &
      (if served.isSome and served.get.isKind(bText): " at " & served.get.text else: "") &
      " (pid " & $pid & ")"
  else: $what & " (pid " & $pid & ")"

proc fits(pid: int, what: Value, s: string): bool =
  ## whether `s` names it: its pid, a jam's name or the port it is served
  ## on (:PORT or HOST:PORT), or bridge for every bridge
  if s.len > 0 and s.allCharsInSet(Digits): return $pid == s
  if ':' in s:
    let served = said(what, "served")
    if served.isNone or not served.get.isKind(bText): return false
    let (want, have) = (s.rsplit(':', 1)[1], served.get.text.rsplit(':', 1)[1])
    return want == have
  if s == "bridge" and what.head == sym"bridge": return true
  what.head == JamQ and what.items.len == 3 and what.items[1].isKind({bSym, bText}) and
    what.items[1].text == s

proc listRunning*(t: Tool, a: Args) =
  if a.positional.len > 0:
    t.misuse "takes no arguments"
  let here = runningHere()
  if here.len == 0:
    chatter "no jam is served and no bridge runs on this machine"
  for r in here: emit r.what

proc stop*(t: Tool, a: Args) =
  if a.positional.len == 0 and not a.has("all"):
    t.misuse "takes what to stop: a pid, a jam's name, :PORT, or bridge (--all stops everything)"
  let here = runningHere()
  var stopping: seq[tuple[pid: int, what: Value]]
  var missed = false
  for s in a.positional:
    let found = here.filterIt(fits(it.pid, it.what, s))
    if found.len == 0:
      chatter "nothing running here is " & s & " (bl jam running lists what is)"
      missed = true
    for r in found:
      if r notin stopping: stopping.add r
  if a.has("all"): stopping = here
  for r in stopping:
    if kill(Pid(r.pid), SIGTERM) != 0:
      chatter "can't stop " & describe(r.pid, r.what) & ": " & $strerror(errno)
      missed = true
      continue
    # gone once it lets go of what it said
    let path = runningDir() / ($r.pid & ".blb")
    for _ in 1 .. 300:
      if not held(path): break
      sleep 10
    discard tryRemoveFile(path)
    chatter "stopped " & describe(r.pid, r.what)
  if missed: quit 1
