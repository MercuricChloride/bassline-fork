{.experimental: "strictFuncs".}
import std/[tables, deques]
import pkg/core
export tables, deques

type
  Word* = object
    prim*: Primitive
    value*: Value
    protected*: bool

  Runtime* = object
    stack*: seq[Value]
    input*: Deque[Value]
    words*: Table[Value, Word]

  RuntimeError* = object of CatchableError

  Primitive* = proc(rt: var Runtime, word: var Word)

template fail*(msg: string) =
  raise newException(RuntimeError, msg)

func initRuntime*(): Runtime =
  Runtime(stack: @[], input: initDeque[Value](), words: initTable[Value, Word]())

func initWord*(prim: Primitive, value: Value = Nil,
  protected = false): Word =
  Word(prim: prim, value: value, protected: protected)

# probing ================

proc done*(rt: var Runtime): bool =
  rt.input.len == 0

proc height*(rt: var Runtime): int =
  rt.stack.len

proc isDefined*(rt: var Runtime, key: Value): bool =
  rt.words.hasKey key

# data stack ================

proc push*(rt: var Runtime, v: varargs[Value]) =
  rt.stack.add v

proc pop*(rt: var Runtime): Value =
  if rt.height == 0:
    fail "pop: stack underflow"
  rt.stack.pop

# runtime input ================

proc feedValue*(rt: var Runtime, v: sink Value) =
  rt.input.addLast v
proc feedValue*(rt: var Runtime, vals: sink seq[Value]) =
  for v in vals:
    rt.feedValue v

proc feedFirst*(rt: var Runtime, v: sink Value) =
  rt.input.addFirst v
proc feedFirst*(rt: var Runtime, vals: sink seq[Value]) =
  for v in vals:
    rt.feedFirst v

proc readValue*(rt: var Runtime): Value =
  rt.input.popFirst

# word definitions ================

proc define*(rt: var Runtime, key: Value, word: sink Word) =
  if not key.marked:
    fail "define: key must be marked"
  if rt.isDefined key:
    fail "define: key already defined"
  rt.words[key] = word

proc define*(rt: var Runtime, key: string, word: sink Word) =
  rt.define(sym(key).mark(true), word)

proc defineMacro*(rt: var Runtime, key: Value, word: sink Word) =
  if key.marked:
    fail "defineMacro: key cannot be marked"
  if rt.isDefined key:
    fail "defineMacro: key already defined"
  rt.words[key] = word

proc defineMacro*(rt: var Runtime, key: string, word: sink Word) =
  rt.defineMacro(sym(key), word)

proc primitive*(rt: var Runtime, key: string, prim: Primitive) =
  rt.define(key, initWord(prim, protected = true))

proc undef*(rt: var Runtime, key: Value, force = false) =
  if not rt.isDefined key:
    fail "undef: no definition for " & $key
  
  if rt.words[key].protected and not force:
    fail "undef: " & $key & "is protected"
  rt.words.del key

proc undef*(rt: var Runtime, key: string, force = false) =
  rt.undef(sym(key).mark(true), force)

proc eval*(rt: var Runtime, val: sink Value) =
  if rt.isDefined(val):
    var word = rt.words[val]
    word.prim(rt, word)
  else:
    rt.push(val)

proc runStep*(rt: var Runtime): bool =
  ## perform one top level step
  ## returns false when done
  if rt.done:
    false
  else:
    rt.eval(rt.readValue())
    true

proc run*(rt: var Runtime) =
  while rt.runStep():
    discard

# word primitives ================

proc docol*(rt: var Runtime, quote: Value) =
  if not quote.isKind(bList):
    fail "docol: requires a list"
  for v in quote.items:
    rt.eval(v)

proc docol*(rt: var Runtime, word: var Word) =
  docol(rt, word.value)

proc dovar*(rt: var Runtime, word: var Word) =
  rt.push word.value