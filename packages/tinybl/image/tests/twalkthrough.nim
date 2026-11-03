## A session the way someone would play: a prototype and two objects made
## from it, a method changed live, the image left and opened again, its
## history read, the change undone, and the undo surviving a session that
## ended without a snapshot.

import std/[os, strutils, times, unittest]
import repl

const dir = "/private/tmp/claude-501/-Users-goose-prg-bassline/c1801c0b-2917-4410-94d9-d8af72683453/scratchpad/walk"

proc one(s: Session, text: string): string =
  let said = s.feed(text)
  check said.len == 1
  said[0]

suite "a session":
  test "make, change live, leave, open again, undo":
    createDir(dir)
    let name = "walk" & $epochTime().int
    var s = openSession(name, dir)
    check s.one("(def counter (make nil {count: 0 next: (fn [] (set count (add count 1)))}))").startsWith("(object")
    discard s.one("(def c1 (make counter {count: 0}))")
    discard s.one("(def c2 (make counter {count: 10}))")
    check s.one("([c1 next])") == "1"
    check s.one("([c2 next])") == "11"

    # changing the prototype's method changes it for both
    discard s.one("(set [counter next] (fn [] (set count (add count 2))))")
    check s.one("([c1 next])") == "3"
    check s.one("([c2 next])") == "13"
    check s.one("nope").startsWith("refused: ")
    s.close

    # a new session holds what the last one left
    s = openSession(name, dir)
    check s.one("(get [c1 count])") == "3"
    check s.one("(get [c2 count])") == "13"
    check s.one("(len (history c1 (quote count)))") != "0"

    # undoing the change to the method
    discard s.one("(def changes (history counter (quote next)))")
    discard s.one("(undo (at (at changes (sub (len changes) 1)) 1))")
    check s.one("([c1 next])") == "4"

    # a session that ends without a snapshot is rebuilt from the log
    s = openSession(name, dir)
    check s.one("([c2 next])") == "14"
    check s.one("(get [c1 count])") == "4"
    s.close
