## The store's laws: an image read back from its snapshot behaves as the
## one written, holds one object wherever the written one held one, keeps
## its cycles and its ids, and refuses what the host can't read.

import std/[os, strutils, unittest]
import core, store

useValue Val

const Scratch = "/private/tmp/claude-501/-Users-goose-prg-bassline/c1801c0b-2917-4410-94d9-d8af72683453/scratchpad"

let sWs = headSym"ws"

layers:
  Unwritten(fd: proc() {.nimcall.})

proc fresh(): Val =
  ## a workspace the root holds, so a snapshot reaches it
  let root = boot()
  result = workspace(root)
  root.slotPut(sWs, result)

proc restored(): Val =
  ## the workspace of the image read back from a snapshot of this one
  snapshot().restore.ownSlot(sWs)

template ev(scope: Val, text: string): Val =
  scope.run(text)

proc parsed(text: string): Val = Val.parse(text)

suite "store":
  test "an image read back behaves as the one written":
    var ws = fresh()
    discard ws.ev """
      (def counter (make nil {count: 0
        next: (fn [] (set count (if count (quote stepped) 0)))}))
      (def c1 (make counter {count: nil}))
      (def m {a: [1 2 3]})
    """
    ws = restored()
    check ws.ev("(>>send (next) c1)") == parsed("0")
    check ws.ev("(>>send (next) c1)") == parsed("stepped")
    check ws.ev("(get [counter count])") == parsed("0")
    discard ws.ev "(set (at (at m (quote a)) 0) 9)"
    check ws.ev("m") == parsed("{a: [9 2 3]}")

  test "an object held in two slots is one object read back":
    var ws = fresh()
    discard ws.ev "(def a (make nil {n: 1})) (def b a) (def h (make nil {x: a}))"
    ws = restored()
    check ws.ev("a").same(ws.ev("b"))
    check ws.ev("(get [h x])").same(ws.ev("a"))
    discard ws.ev "(set [a n] 2)"
    check ws.ev("(get [b n])") == parsed("2")

  test "cycles survive":
    var ws = fresh()
    discard ws.ev "(def a (make nil)) (set [a me] a)"
    ws = restored()
    check ws.ev("(get [a me])").same(ws.ev("a"))
    check ws.ev("[>>root-scope]").kind == bList
    check image.root.ownSlot(headSym">>root-scope").same(image.root)

  test "ids survive":
    var ws = fresh()
    discard ws.ev "(def a (make nil {n: 1}))"
    let
      before = ws.ev("(id-of a)")
      wsId = ws.idOf
      rootId = image.root.idOf
    ws = restored()
    check ws.ev("(id-of a)") == before
    check ws.idOf == wsId
    check image.root.idOf == rootId
    check ws.ev("(id (id-of a))").same(ws.ev("a"))

  test "natives still work":
    var ws = fresh()
    ws = restored()
    check ws.ev("(if nil 1 2)") == parsed("2")
    check ws.ev("(quote (x y))") == parsed("(x y)")
    check ws.ev("(do (def z 3) z)") == parsed("3")
    check ws.ev("(layer if doc)").kind == bRec

  test "a function made in a call still works read back":
    var ws = fresh()
    discard ws.ev "(def keep (fn [n] (fn [] n))) (def k5 (keep 5))"
    ws = restored()
    check ws.ev("(k5)") == parsed("5")
    check ws.ev("((keep 6))") == parsed("6")

  test "a missing native is refused by its name":
    let snap = parsed("(image {root: 0x01 at: 0 objects: {0x01: {(native nope)}}})")
    try:
      discard snap.restore
      check false
    except BasslineError as e:
      check "no native named nope" in e.msg

  test "a layer with no written form is left out and said lost":
    let ws = fresh()
    discard ws.ev "(def o (make nil {n: 1}))"
    let o = ws.ev("o")
    o.layers.add newUnwritten(nil)
    let snap = snapshot()
    check $snap.getChild(1).dict.getOr(headSym"lost", null) == "[" & $o.idOf & "]"
    let back = snap.restore.ownSlot(sWs)
    check back.ev("(get [o n])") == parsed("1")

  test "a snapshot with nothing lost says nothing of it":
    discard fresh()
    check snapshot().getChild(1).dict.getOr(headSym"lost", nil).isNil

  test "a file round trip":
    let path = Scratch / "tstore.image.blb"
    var ws = fresh()
    discard ws.ev "(def a (make nil {n: [1 2]})) (def b (fn [x] x))"
    saveImage(path, 7)
    check fileExists(path & ".bl")
    let (root, at) = loadImage(path)
    check at == 7
    ws = root.ownSlot(sWs)
    check ws.ev("(get [a n])") == parsed("[1 2]")
    check ws.ev("(b (quote ok))") == parsed("ok")
    removeFile(path)
    removeFile(path & ".bl")
