## The history's laws: the log replayed onto the snapshot it began from is
## the live image, undoing restores what was and appends without erasing,
## an evaluation's changes are its group, and the file holds what memory
## holds.

import std/[os, unittest]
import core, store, history

useValue Val

const Scratch = "/private/tmp/claude-501/-Users-goose-prg-bassline/c1801c0b-2917-4410-94d9-d8af72683453/scratchpad"

let sWs = headSym"ws"

var path: string

proc fresh(name: string): Val =
  ## a workspace the root holds, its history kept in a new log
  path = Scratch / name & ".log.blb"
  if fileExists(path):
    removeFile(path)
  let root = boot()
  result = workspace(root)
  root.slotPut(sWs, result)
  startHistory(path, "test")

proc ev(scope: Val, text: string): Val =
  ## each form in text evaluated in scope as its own logged evaluation
  result = null
  for form in Val.parseMany(text):
    discard evaluating(form)
    try:
      result = form.eval(scope)
    except BasslineError as e:
      refusedEval(form, e.msg)
      raise
    evaluated()

proc parsed(text: string): Val = Val.parse(text)

proc kindOf(entry: Val): string = entry.eventOf.getChild(0).text

proc lastOfKind(kind: string): int =
  for entry in entries():
    if entry.kindOf == kind:
      result = entry.numberOf

suite "history":
  test "the log replayed onto the snapshot it began from is the live image":
    let ws = fresh("replay")
    let start = snapshot(lastEntry())
    discard ws.ev """
      (def counter (make nil {count: 0
        next: (fn [] (set count (if count (quote stepped) 0)))}))
      (def c1 (make counter {count: nil}))
      (>>send (next) c1)
      (def o (make nil {n: 1}))
      (set (layer o doc) (quote (doc "an o")))
      (set (layer o cell) (quote (cell 1)))
      (>>send (>>put 2) o)
      (set (layer o doc) (quote (doc "still an o")))
      (def keep (fn [n] (fn [] n)))
      (def k5 (keep 5))
      (def m {a: [1 2]})
      (set (at (at m (quote a)) 0) 9)
    """
    let live = snapshot(0)
    discard start.restore
    replay(entries(), start.atOf)
    check snapshot(0) == live
    let back = image.root.ownSlot(sWs)
    check back.ev("(k5)") == parsed("5")
    check back.ev("(get [c1 count])") == parsed("0")

  test "the file holds what memory holds":
    let ws = fresh("file")
    discard ws.ev "(def x 1) (set x 2) (def o (make nil {n: [1]}))"
    check readLog(path) == entries()

  test "undoing a change puts back what was":
    let ws = fresh("undo-change")
    discard ws.ev "(def x 1) (set x 2)"
    undo(lastOfKind("changed"))
    check ws.ev("x") == parsed("1")

  test "undoing a define removes the slot":
    let ws = fresh("undo-define")
    discard ws.ev "(def y 5)"
    undo(lastOfKind("defined"))
    expect BasslineError:
      discard ws.ev("y")

  test "undoing appends and erases nothing":
    let ws = fresh("undo-appends")
    discard ws.ev "(def x 1) (set x 2)"
    let
      before = entries()
      n = lastOfKind("changed")
    undo(n)
    let after = entries()
    check after.len > before.len
    check after[0 ..< before.len] == before
    check after[before.len].eventOf == bl"(undid $n)"
    check after[before.len + 1].triggerOf == after[before.len].numberOf

  test "an evaluation's changes take it as their trigger":
    let ws = fresh("trigger")
    let n = evaluating(parsed("(do (def a 1) (def b 2))"))
    discard parsed("(do (def a 1) (def b 2))").eval(ws)
    evaluated()
    var caused: seq[string]
    for entry in entries():
      if entry.triggerOf == n:
        caused.add entry.kindOf
    check caused == @["defined", "defined"]

  test "undoing an evaluation undoes all it did":
    let ws = fresh("undo-group")
    discard ws.ev "(def keep 0) (do (def a 1) (set keep 7))"
    undo(lastOfKind("evaluated"))
    check ws.ev("keep") == parsed("0")
    expect BasslineError:
      discard ws.ev("a")

  test "undoing an undo does it again":
    let ws = fresh("redo")
    discard ws.ev "(def x 1) (set x 2)"
    undo(lastOfKind("changed"))
    check ws.ev("x") == parsed("1")
    undo(lastOfKind("undid"))
    check ws.ev("x") == parsed("2")

  test "undoing a layer put back the one it replaced":
    let ws = fresh("undo-layer")
    discard ws.ev """
      (def o (make nil))
      (set (layer o doc) (quote (doc "first")))
      (set (layer o doc) (quote (doc "second")))
    """
    undo(lastOfKind("layered"))
    check ws.ev("(layer o doc)") == parsed("(doc \"first\")")

  test "a refused evaluation is logged with its words":
    let ws = fresh("refused")
    expect BasslineError:
      discard ws.ev("nope")
    let last = entries()[^1]
    check last.kindOf == "refused"
    check last.eventOf.getChild(1) == parsed("nope")

  test "reopening the log carries on its numbering":
    let ws = fresh("reopen")
    discard ws.ev "(def x 1)"
    let n = lastEntry()
    startHistory(path, "again")
    check lastEntry() == n
    discard ws.ev "(set x 2)"
    check entries()[n].numberOf == n + 1
    check readLog(path).len == lastEntry()

  test "history finds the entries for an object":
    let ws = fresh("find")
    discard ws.ev "(def o (make nil {n: 1})) (set [o n] 2) (set [o n] 3) (set [o m] 0)"
    check ws.ev("(history o (quote n))").len == 2
    check ws.ev("(history o)").len == 4
    check ws.ev("(entry 1)") == entries()[0]
    check ws.ev("(entries 2 3)").len == 2
    let n = lastOfKind("changed")
    discard ws.ev("(undo " & $n & ")")
    check ws.ev("(get [o n])") == parsed("2")
