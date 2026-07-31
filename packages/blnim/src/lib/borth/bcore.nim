import pkg/core
import pkg/lib/print
import ./runtime

func allKind(kinds: set[BlKind], values: varargs[Value]): bool =
  for v in values:
    if not v.isKind(kinds):
      return false
  true

template op*(name, body) =
  proc name(
    rt {.inject.}: var Runtime,
    w {.inject.}: var Word) =
    body

template unary(a, body) =
  let a = pop rt
  body

template binary(a, b, body) =
  let
    b = pop rt
    a = pop rt
  body

template numeric(name, body) =
  binary a, b:
    if not allKind({bNum}, a, b):
      fail name & ": requires 2 numbers"
    body

## numeric ops ================
op addOp:
  numeric "add":
    rt.push num(a.num + b.num)

op subOp:
  numeric "sub":
    rt.push num(a.num - b.num)

op mulOp:
  numeric "mul":
    rt.push num(a.num * b.num)

op divOp:
  numeric "div":
    rt.push num(a.num div b.num)

## collections ================

op atOp:
  binary val, key:
    rt.push get(val[key])

## stack manipulation ================

op dupOp:
  unary a:
    rt.push a, a

op dropOp:
  discard rt.pop()

op swapOp:
  binary a, b:
    rt.push b, a

op rotOp:
  let 
    c = rt.pop
    b = rt.pop
    a = rt.pop
  rt.push c, a, b

op takeOp:
  unary amount:
    if amount.kind != bNum:
      fail "take: amount not a number"
    let n = amount.num.parseInt()
    if n > rt.height:
      fail "take: amount > stack height"
    var items = newSeq[Value](n)
    for i in countDown(n - 1, 0):
      items[i] = rt.pop()
    rt.push list(items)

op heightOp:
  rt.push num(rt.height)

op spliceOp:
  unary a:
    if not a.isKind(bList):
      fail "splice-all: requires a list"
    for v in a.ravel:
      rt.push v

## definitions ================

op defOp:
  binary quote, name:
    if not quote.isKind(bList):
      fail "def: quote must be a list"
    if name.marked:
      fail "def: name must not be marked!"
    rt.define(name.mark(true), Word(prim: docol, value: quote, protected: false))

op defMacroOp:
  binary quote, name:
    if not quote.isKind(bList):
      fail "macro: quote must be a list"
    if not name.isKind(bSym):
      fail "macro: name must be an unmarked symbol"
    if name.marked:
      fail "macro: name cannot be marked!"
    rt.defineMacro(name, Word(prim: docol, value: quote, protected: false))

op varOp:
  unary name:
    if name.marked:
      fail "def: name must not be marked!"
    if rt.isDefined(name):
      return
    rt.define(
      name.mark(true), 
      Word(prim: dovar, value: Nil, protected: false))

op setOp:
  binary val, name:
    rt.words[name.mark(true)].value = val

op readOp:
  unary name:
    rt.push rt.words[name.mark(true)].value

op wordsOp:
  var wordSet: seq[Value] = @[]
  for k in rt.words.keys:
    wordSet.add k
  rt.push set(wordSet)

# ================ evaluation ================

op doOp:
  docol(rt, rt.pop())

# ================ io ================

op readValueOp:
  rt.push rt.readValue()

op readUntilOp:
  unary stop:
    if stop.marked:
      fail "readUntil: stop cannot be marked!"
    var items: seq[Value] = @[]
    while true:
      let v = rt.readValue()
      if v == stop:
        break
      else:
        items.add v
    rt.push list(items)

op iotaOp:
  unary n:
    var items: seq[Value] = @[]
    if not n.isKind(bNum):
      fail "iota: not a number"
    for i in countup(0, n.num.parseInt() - 1, 1):
      items.add num(i)
    rt.push list(items)

op echoOp:
  echo rt.pop

proc installCore*(rt: var Runtime) =
  rt.primitive "add", addOp
  rt.primitive "sub", subOp
  rt.primitive "mul", mulOp
  rt.primitive "div", divOp

  rt.primitive "dup", dupOp
  rt.primitive "drop", dropOp
  rt.primitive "swap", swapOp
  rt.primitive "rot", rotOp
  rt.primitive "take", takeOp
  rt.primitive "splice", spliceOp

  rt.primitive "stack-height", heightOp

  rt.primitive "define", defOp
  rt.primitive "macro", defMacroOp
  rt.primitive "var", varOp
  rt.primitive "set", setOp
  rt.primitive "read", readOp
  rt.primitive "words", wordsOp

  rt.primitive "at", atOp

  rt.primitive "do", doOp

  rt.primitive "read-until", readUntilOp
  rt.primitive "read-value", readValueOp
  rt.primitive "echo", echoOp
  rt.primitive "iota", iotaOp