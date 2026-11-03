## bli: a session on an image. `bli NAME` opens NAME.image.blb and
## NAME.log.blb in the current directory, or begins them, and evaluates
## what is typed in the image's workspace. Everything said is logged, so
## the log rebuilds the image from its last snapshot, and leaving writes a
## new snapshot.

import std/[os, rdstdin, strutils, times]
import library, store, history

refuseWith BasslineError

useValue Val

type Session* = ref object
  name*, imagePath*, logPath*: string
  root*, workspace*: Val
  quitting*: bool

var current: Session

let sWorkspace = headSym"workspace"

proc openSession*(name: string, dir = "."): Session =
  ## the session on the image name, begun when there is none yet
  result = Session(
    name: name,
    imagePath: dir / name & ".image.blb",
    logPath: dir / name & ".log.blb")
  let session = $getTime().toUnix
  if fileExists(result.imagePath):
    let (root, at) = loadImage(result.imagePath)
    result.root = root
    startHistory(result.logPath, session)
    replay(entries(), at)
  else:
    result.root = bootLibrary()
    startHistory(result.logPath, session)
    saveImage(result.imagePath, lastEntry())
  result.workspace = result.root.ownSlot(sWorkspace)
  if result.workspace.isNil:
    result.workspace = workspace(result.root)
    result.root.slotPut(sWorkspace, result.workspace)
  current = result

proc save*(s: Session) =
  saveImage(s.imagePath, lastEntry())

proc close*(s: Session) =
  s.save

proc depth(text: string): int =
  ## how many frames text leaves open, outside quoted text
  var quoted = false
  var escaped = false
  for c in text:
    if quoted:
      if escaped: escaped = false
      elif c == '\\': escaped = true
      elif c == '"': quoted = false
    else:
      case c
      of '"': quoted = true
      of '(', '[', '{': inc result
      of ')', ']', '}': dec result
      else: discard

proc isIncomplete*(text: string): bool = text.depth > 0

proc feed*(s: Session, text: string): seq[string] =
  ## each value text holds evaluated in the workspace, with what it answers
  ## or the words it was refused with
  var forms: seq[Val]
  try:
    forms = Val.parseMany(text)
  except Exception as e:
    return @["not values: " & e.msg]
  for form in forms:
    discard evaluating(form)
    try:
      let answer = form.eval(s.workspace)
      evaluated()
      result.add $answer
    except BasslineError as e:
      refusedEval(form, e.msg)
      result.add "refused: " & e.msg
    if s.quitting:
      break

{.push raises: [BasslineError].}

proc saveN(msg, self, sender: Val): Val {.native: "save".} =
  ## (save)
  ## Writes a snapshot of the image, so it opens without replaying the log.
  guard not current.isNil, "no session to save"
  try:
    current.save
  except CatchableError as e:
    refuse "can't save: " & e.msg
  bl"saved"

proc quitN(msg, self, sender: Val): Val {.native: "quit".} =
  ## (quit)
  ## Ends the session, after a snapshot.
  guard not current.isNil, "no session to quit"
  current.quitting = true
  bl"bye"

proc runFileN(msg, self, sender: Val): Val {.native: "run-file".} =
  ## (run-file PATH)
  ## Each value in the file at PATH evaluated here, answering the last.
  let a = msg.args(sender)
  guard a.len == 1 and a[0].kind == bText, "(run-file PATH): " & $msg
  var text: string
  try:
    text = readFile(a[0].text)
  except CatchableError as e:
    refuse "can't read " & a[0].text & ": " & e.msg
  sender.run(text)

{.pop.}

when isMainModule:
  let name = if paramCount() >= 1: paramStr(1) else: "scratch"
  let s = openSession(name)
  echo "bli: ", s.imagePath, ", ", lastEntry(), " entries. (man) to begin, (quit) to leave."
  var buffer = ""
  while not s.quitting:
    var line: string
    if not readLineFromStdin(if buffer.len == 0: "bl> " else: ".. ", line):
      break
    buffer.add line
    buffer.add '\n'
    if buffer.isIncomplete:
      continue
    if buffer.strip.len > 0:
      for each in s.feed(buffer):
        if each != "nil":
          echo each
    buffer = ""
  s.close
