import std/strformat
import fusion/matching
import ../[core, ops]
import ./lattice

type
  CellBase* = ref object of RootObj

  Cell*[T: Lattice] = ref object of CellBase
    current: T
    callbacks*: seq[proc(val: T)]

proc newCell*[T: Lattice](init: T = T.bottom): Cell[T] =
  Cell[T](current: init, callbacks: @[])

proc cell*[T: Lattice](_: type T): Cell[T] =
  newCell[T]()

proc `$`*(self: Cell): string =
  fmt"Cell[{$self.T} {$self.value}]"

proc value*(self: Cell): lent self.T =
  self.current

proc `cb=`*[T: Lattice](self: Cell[T], cb: proc(val: T)) =
  self.callbacks = @[cb]

proc onChange*[T: Lattice](self: Cell[T], cb: proc(val: T)) = 
  self.callbacks.add cb

proc notify*(self: Cell, val: self.T = self.value) =
  for cb in self.callbacks:
    cb(val)

proc reset*(self: Cell, val = self.T.bottom) =
  self.current = val
  self.notify(val)

proc reset*[T: Lattice](cells: varargs[Cell[T]]) =
  for c in cells:
    reset c

proc `value=`*(self: Cell, val: self.T) =
  let (value, didChange) = merge(self.current, val)
  if didChange:
    self.current = value
    self.notify value

proc `@`*(self: Cell): auto =
  self.value

proc add*(self: Cell, val: self.T) =
  self.value = val

proc add*[T: ValueLattice](self: Cell[T], val: Value) =
  self.value = T.fromValue(val)

template changed*(self: Cell, body: untyped) =
  self.callbacks.add(proc(it{.inject.}: auto) = body)

template watch*(inputs: untyped, body: untyped) =
  proc compute() =
    body
  for input in inputs:
    input.onChange(proc(_: auto) = compute())

proc pid*(a,b: Cell) =
  a.changed: b &= it

proc same*(a, b: Cell) =
  pid(a, b)
  pid(b, a)

proc same*(self: Cell): Cell =
  result = newCell[self.T]()
  same(self, result)

template cellBinaryOp*(prim, op) =
  proc prim*(a,b,c:Cell) =
    watch [a,b]:
      c.value = op(@a, @b)
  proc `op`*(a,b: Cell): Cell =
    result = newCell[a.T]()
    prim(a,b,result)

cellBinaryOp padd, `+`
cellBinaryOp psub, `-`
cellBinaryOp pmul, `*`
cellBinaryOp pdiv, `div`
cellBinaryOp pmod, `mod`

type
  Binary[T] = tuple
    a,b,c: Cell[T]

proc adder[T](net: Binary[T]) =
  let (a, b, c) = net
  padd(a, b, c)
  psub(c, b, a)
  psub(c, a, b)

when isMainModule:
  let
    a = cell Numeric
    b = same a
    c = a * b

  c.changed:
    echo "c: ", it

  a &= 1..10
  a &= 2..8
  a &= 7

  reset a, b, c

  a &= 15

  let
    all = cell BSet
    nogood = cell BSet

  assert BSet is ValueLike
  assert BSet is ValueLattice

  var good: BSet

  watch [all, nogood]:
    good = @all - @nogood

  all &= readValue"{foo bar hello world}"

  echo "first: ",  good.toValue()

  nogood &= readValue"{hello world}"

  echo "second: ", good.toValue()

  let foo: Binary[Numeric] = (a, cell Numeric, c)

  adder foo

  a.notify

  echo foo