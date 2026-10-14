## The jams kept on this machine, each a log in ~/.bl/jams, NAME.blb:
## `bl jam serve --as NAME` serves one, `--new` begins one, and
## `bl jam list` says what each holds. A jam being served holds its log
## locked, so it is served once, and while it is, says where beside it,
## in NAME.at

import std/[algorithm, options, os, posix, strutils]
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
