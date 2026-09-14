import ./[core, ops, lattice]

type
  Cell*[T: Lattice] = ref object
    current: T
    callbacks*: seq[proc(val: T)]

proc newCell*[T: Lattice](init: T = T.bottom): Cell[T] =
  Cell[T](current: init, callbacks: @[])

proc cell*[T: Lattice](_: type T): Cell[T] =
  newCell[T]()

proc value*(self: Cell): lent self.T =
  self.current

proc `cb=`*[T: Lattice](self: Cell[T], cb: proc(val: T)) =
  self.callbacks = @[cb]

proc onChange*[T: Lattice](self: Cell[T], cb: proc(val: T)) = 
  self.callbacks.add cb

proc notify*(self: Cell, val: self.T) =
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

template changed*(self: Cell, body: untyped) =
  self.callbacks.add(proc(it{.inject.}: auto) = body)

template watch*(inputs: untyped, body: untyped) =
  proc compute() =
    body
  for input in inputs:
    input.onChange(proc(_: auto) = compute())

proc id*(a,b: Cell) =
  a.changed: b &= it

proc same*(a, b: Cell) =
  id(a, b)
  id(b, a)

proc same*(self: Cell): Cell =
  result = newCell[self.T]()
  same(self, result)

template cellBinaryOp*(name, op) =
  proc name*(a,b,c:Cell) =
    watch [a,b]:
      c.value = op(@a, @b)
  proc `op`*(a,b: Cell): Cell =
    result = newCell[a.T]()
    name(a,b,result)

cellBinaryOp add, `+`
cellBinaryOp sub, `-`
cellBinaryOp mul, `*`
cellBinaryOp `div`, `div`
cellBinaryOp `mod`, `mod`

when isMainModule:
  let
    a = cell Numeric
    b = same a
    c = a * b

  mul(a,b,c)

  c.changed:
    echo "c: ", it

  a &= 1..10
  a &= 2..8
  a &= 7

  reset a, b, c

  a &= 15..20