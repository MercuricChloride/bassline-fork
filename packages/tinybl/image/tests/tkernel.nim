## The kernel's laws: names are found by delegation, a prototype's function
## runs with the receiver as self, a function made in a call keeps that
## call, places nest, layers are places, and what enters the image gets an
## id and is said as events.

import std/unittest
import core

useValue Val

var heard: seq[Val]

proc hear(event: Val) {.nimcall, raises: [].} =
  heard.add event

proc fresh(): Val =
  ## a workspace below a newly booted root
  discard boot()
  image.listeners = @[Listener(hear)]
  heard = @[]
  workspace(image.root)

template ev(scope: Val, text: string): Val =
  scope.run(text)

proc parsed(text: string): Val = Val.parse(text)

suite "kernel":
  test "names are found by delegation":
    let ws = fresh()
    discard ws.ev "(def x 1)"
    check ws.ev("x") == parsed("1")
    check ws.ev("(do (def f (fn [] x)) (f))") == parsed("1")
    expect BasslineError:
      discard ws.ev "nope"

  test "quote, if and do":
    let ws = fresh()
    check ws.ev("(quote (a b))") == parsed("(a b)")
    check ws.ev("(if nil 1 2)") == parsed("2")
    check ws.ev("(if 0 1 2)") == parsed("1")
    check ws.ev("(if nil 1)") == parsed("nil")
    check ws.ev("!(do 1 2 3)") == parsed("3")

  test "a prototype's function runs with the receiver as self":
    let ws = fresh()
    discard ws.ev """
      (def counter (make nil {count: 0
        next: (fn [] (set count (if count (quote stepped) 0)))}))
      (def c1 (make counter {count: 5}))
    """
    check ws.ev("(>>send (next) c1)") == parsed("stepped")
    check ws.ev("(get [c1 count])") == parsed("stepped")
    check ws.ev("(slot c1 (quote count))") == parsed("stepped")
    check ws.ev("(slot counter (quote count))") == parsed("0")
    check ws.ev("([counter next])") == parsed("stepped")
    check ws.ev("[c1 count]") == parsed("[c1 count]")

  test "a function made in a call keeps that call":
    let ws = fresh()
    discard ws.ev "(def keep (fn [n] (fn [] n)))"
    check ws.ev("((keep 5))") == parsed("5")
    check ws.ev("((keep (quote seven)))") == parsed("seven")

  test "op gets its message and sender unevaluated":
    let ws = fresh()
    discard ws.ev "(def form-of (op >>message))"
    check ws.ev("(form-of (a b) c)") == parsed("(form-of (a b) c)")
    discard ws.ev "(def y 9)"
    check ws.ev("((op (eval (quote y) >>sender)))") == parsed("9")

  test "set through nested at rebuilds and puts back":
    let ws = fresh()
    discard ws.ev "(def m {a: [1 2 3] b: 4})"
    discard ws.ev "(set (at (at m (quote a)) 1) 9)"
    check ws.ev("m") == parsed("{a: [1 9 3] b: 4}")
    check ws.ev("(at (at m (quote a)) 1)") == parsed("9")
    discard ws.ev "(set (at m (quote b)) (quote x))"
    check ws.ev("m") == parsed("{a: [1 9 3] b: x}")

  test "a reference as an object":
    let ws = fresh()
    discard ws.ev "(def x 1)"
    discard ws.ev "(def r (ref x))"
    discard ws.ev "(>>send (>>put 2) r)"
    check ws.ev("x") == parsed("2")
    check ws.ev("(>>send (>>get) r)") == parsed("2")

  test "layers are places":
    let ws = fresh()
    discard ws.ev "(def o (make nil {a: 1}))"
    check ws.ev("(layer o doc)") == parsed("nil")
    discard ws.ev "(set (layer o doc) (quote (doc \"an o\")))"
    check ws.ev("(layer o doc)") == parsed("(doc \"an o\")")
    check ws.ev("(layers o)") == parsed("{(doc \"an o\") (slots {a: 1})}")
    discard ws.ev "(set (layer o doc) nil)"
    check ws.ev("(layers o)") == parsed("{(slots {a: 1})}")
    discard ws.ev "(set (layers o) (quote {(slots {b: 2}) (cell 3)}))"
    check ws.ev("(slot o (quote b))") == parsed("2")
    check ws.ev("(>>send (>>get) o)") == parsed("3")

  test "the root holds the natives, with their docs":
    let ws = fresh()
    check ws.ev("(layer if doc)").kind == bRec
    check ws.ev("((native quote) x)") == parsed("x")
    check ws.ev("[>>root-scope quote]").kind == bList

  test "what enters the image gets an id and is said":
    let ws = fresh()
    discard ws.ev "(def o (make nil {inner: (make nil {n: 1})}))"
    let o = ws.ev("o")
    check not o.idOf.isNil
    check ws.ev("(id-of (slot o (quote inner)))").kind == bBytes
    var kinds: seq[string]
    for e in heard:
      kinds.add e.getChild(0).text
    check "created" in kinds
    check "defined" in kinds
    discard ws.ev "(set [o inner] 2)"
    check heard[^1].getChild(0).text == "changed"
    check ws.ev("(id (id-of o))") == o

  test "an object's written form names what it holds by id":
    let ws = fresh()
    discard ws.ev "(def o (make nil {inner: (make nil {n: 1})}))"
    let
      o = ws.ev("o")
      inner = ws.ev("(slot o (quote inner))")
      written = o.objectForm.ce
      read = fromCE(written)
    check read.getChild(0) == parsed("object")
    check $read.getChild(2) == "{(slots {inner: (object " & $inner.idOf & ")})}"

  test "written objects read back as the objects they name":
    let ws = fresh()
    discard ws.ev "(def o (make nil {n: 1}))"
    let
      o = ws.ev("o")
      written = fromCE(bl"[(x 1) {k: $o}]".ce)
      read = written.withObjects
    check read.getChild(1).dict.vals[0].same(o)
    let unknown = fromCE(bl"(object 0x00112233)".ce).withObjects
    check unknown.isObject
    check unknown.idOf == Val.parse("0x00112233")
