import std/[strformat, sequtils, deques, sets]
import ../core
import ./lattice

type
  NetworkError = object of CatchableError
  ValueMerge* = proc(prev, curr: Value): Merged[Value] {.nimcall.}

  NetworkEventKind* = enum
    nekRun, nekMerge

  NetworkEvent* = object
    case kind*: NetworkEventKind
    of nekMerge:
      cell*: Cell
      value*: Value
    of nekRun:
      prop*: Prop

  Net* = ref object of RootObj
    cells*: HashSet[Cell]
    props*: HashSet[Prop]
    primaryEvents: Deque[NetworkEvent]
    secondaryEvents: Deque[NetworkEvent]
    running: bool
    gas: int

  Element* = ref object of RootObj
    net*: Net
    active* = true

  Cell* = ref object of Element
    inputs*, outputs*: HashSet[Prop]
    current*: Value
    mergeProc*: ValueMerge

  Prop* = ref object of Element
    inputs*: seq[Cell]
    outputs*: HashSet[Cell]
    shouldRunProc*: proc(values: varargs[Value]): bool
    runProc*: proc(values: varargs[Value]): Value

  Group* = ref object of Element
    elements*: HashSet[Element]

refuseWith NetworkError

proc `$`*(self: Cell): string =
  $(self.current)

proc `$`*(self: Net): string =
  result &= "cells:\n"
  for cell in self.cells:
    result &= fmt("{$cell}\n")

proc `$`*(self: NetworkEvent): string =
  case self.kind
  of nekRun:
    "Run"
  of nekMerge:
    fmt"Merge[{self.cell.current} {self.value}]"

# ================ Network Events ================

proc schedule*(self: Net, event: NetworkEvent) =
  if not self.running:
    self.primaryEvents.addLast event
  else:
    self.secondaryEvents.addLast event

iterator primary*(self: Net): NetworkEvent =
  while true:
    if self.primaryEvents.len == 0: break
    yield self.primaryEvents.popFirst()

iterator secondary*(self: Net): NetworkEvent =
  while true:
    if self.secondaryEvents.len == 0: break
    yield self.secondaryEvents.popFirst()

proc runEvent(prop: Prop): NetworkEvent =
  NetworkEvent(kind: nekRun, prop: prop)

proc mergeEvent(cell: Cell, value: Value): NetworkEvent =
  NetworkEvent(kind: nekMerge, cell: cell, value: value)

proc runnable(self: Prop): bool =
  self.active and self.inputs.allIt(it.active)

proc scheduleRun(self: Net, prop: Prop) =
  if prop in self.props and prop.runnable:
    self.schedule runEvent(prop)

proc scheduleMerge(self: Net, cell: Cell, value: Value) =
  if cell in self.cells and cell.active:
    self.schedule mergeEvent(cell, value)

proc notify*(self: Cell)
proc run*(self: Prop)

method doEnable*(self: Element) {.base.} =
  self.active = true

method doEnable*(self: Cell) =
  self.active = true
  for prop in self.outputs:
    doEnable prop
  self.notify

method doEnable*(self: Group) =
  self.active = true
  for el in self.elements:
    doEnable el

method doDisable*(self: Element) {.base.} =
  self.active = false

method doDisable*(self: Group) =
  self.active = false
  for el in self.elements:
    doDisable el

proc enable*(els: varargs[Element]) =
  for el in els:
    doEnable(el)

proc disable*(els: varargs[Element]) =
  for el in els:
    doDisable(el)

# ================ Event Handling ================

proc add*(self: Cell, val: Value)
proc doMerge(self: Cell, val: Value)

proc doRun(self: Prop) =
  if self notin self.net.props or not self.runnable:
    return
  var values = newSeq[Value](self.inputs.len)
  for i, cell in self.inputs:
    values[i] = cell.current
  if self.shouldRunProc(values):
    let res = self.runProc(values)
    for cell in self.outputs:
      cell.add res

proc handleEvent(self: Net, event: NetworkEvent) =
  case event.kind
  of nekRun:
    doRun(event.prop)
  of nekMerge:
    doMerge(event.cell, event.value)

proc stepMain*(self: Net): bool =
  ## returns true if the network is quiescent
  self.running = true
  defer:
    self.running = false
  for em in self.primary:
    self.handleEvent(em)
    for es in self.secondary:
      self.handleEvent(es)
    guard self.secondaryEvents.len == 0, "not finished"
    return false
  true

proc run*(self: Net) =
  while true:
    if self.stepMain: break
  doAssert self.primaryEvents.len == 0
  doAssert self.secondaryEvents.len == 0

# ================ Connections ================

proc `->`*[A, B](a: A, b: B): auto {.discardable.} =
  a.connectTo(b)

proc connectTo*(self: Cell, prop: Prop): Prop =
  self.outputs.incl prop
  prop.inputs.add self
  prop

proc connectTo*(self: Prop, cell: Cell): Cell =
  self.outputs.incl cell
  cell.inputs.incl self
  cell

proc connectTo*(
    cells: openArray[Cell], 
    prop: Prop): Prop =
  for cell in cells:
    cell -> prop
  prop

proc connectTo*(
    prop: Prop, 
    cells: openArray[Cell]) =
  for cell in cells:
    prop -> cell

# ================ Propagators ================

proc run*(self: Prop) =
  self.net.scheduleRun(self)

template punary*(fn): Prop.runProc =
  proc(values: varargs[Value]): Value =
    guard values.len == 1, "unary requires 1 argument"
    fn(values[0])

template pbinary*(fn): Prop.runProc =
  proc(values: varargs[Value]): Value =
    guard values.len == 2, "binary requires 2 arguments"
    fn(values[0], values[1])

template pternary*(fn): Prop.runProc =
  proc(values: varargs[Value]): Value =
    guard values.len == 3, "ternary requires 3 arguments"
    fn(values[0], values[1], values[2])

proc noneNull*(values: varargs[Value]): bool =
  for v in values:
    if v == null(): return false
  true

proc identity*(a: Value): Value = a

template numeric(name, op): untyped =
  proc name*(a, b: Value): Value =
    let (x, y) = fromValue[Numeric](a, b)
    toValue(op(x, y))

numeric addNumeric, `+`
numeric subNumeric, `-`
numeric mulNumeric, `*`
numeric divNumeric, `div`

# ================ Cells ================

proc notify*(self: Cell) =
  for p in self.outputs:
    self.net.scheduleRun p

proc doMerge(self: Cell, val: Value) =
  let
    (value, didChange) = self.mergeProc(self.current, val)
  if didChange:
    self.current = value
    self.notify

proc add*(self: Cell, val: Value) =
  self.net.scheduleMerge(self, val)

proc add*(self: Cell, val: string) =
  self.add readValue(val)

# ================ Groups ================

iterator props*(self: Group): Prop =
  for e in self.elements:
    if e of Prop: yield Prop(e)

iterator cells*(self: Group): Cell =
  for e in self.elements:
    if e of Cell: yield Cell(e)

iterator groups*(self: Group): Group =
  for e in self.elements:
    if e of Group: yield Group(e)

# ================ Constructors ================

proc newNetwork*(gas = 1_000_000): Net =
  Net(gas: gas)

proc newCell*(
    self: Net, merge: ValueMerge, current: Value = null()): Cell =
  result = Cell(net: self, mergeProc: merge, current: current, active: true)
  self.cells.incl result

proc newCell*[T: ValueLattice](self: Net, _: type T): Cell =
  proc doMerge(p, c: Value): Merged[Value] =
      let
        prev = T.fromValue(p)
        curr = T.fromValue(c)
        (value, didChange) = prev.merge(curr)
      (value.toValue, didChange)
  self.newCell(doMerge, toValue(T.bottom()))

proc newProp*(
    self: Net,
    runProc: Prop.runProc, 
    shouldRunProc: Prop.shouldRunProc = noneNull
  ): Prop =
  result = Prop(
    net: self, 
    runProc: runProc,
    shouldRunProc: shouldRunProc,
    active: true)
  self.props.incl result

proc newProp*(
    self: Net,
    inputs: openArray[Cell],
    outputs: openArray[Cell],
    runProc: Prop.runProc, 
    shouldRunProc: Prop.shouldRunProc = noneNull
  ): Prop =
  result = self.newProp(runProc, shouldRunProc)
  self.props.incl result
  inputs -> result -> outputs
  run result

proc prop*(
    self: Group,
    runProc: Prop.runProc, 
    shouldRunProc: Prop.shouldRunProc = noneNull
  ): Prop =
  result = self.net.newProp(runProc, shouldRunProc)
  if not self.active: disable result
  self.elements.incl result

proc cell*(self: Group, merge: ValueMerge, current: Value = null()): Cell =
  result = self.net.newCell(merge, current)
  if not self.active: disable result
  self.elements.incl result

proc cell*[T: ValueLattice](self: Group, _: type T): Cell =
  result = self.net.newCell(T)
  if not self.active: disable result
  self.elements.incl result

proc newGroup*(self: Net, active = false): Group =
  Group(net: self, active: active)

# ================ Utility Groups ================

template withGroup*(g: Group, body: untyped): untyped {.dirty.} =
  ##[
  A helper template that allows for easier definition of groups.
  ]##
  template cell(a): untyped = g.cell(a)
  template cell(a, b): untyped = g.cell(a, b)
  template cell(a, b, c): untyped = g.cell(a, b, c)
  template prop(a): untyped = g.prop(a)
  template unary(f): untyped = prop(punary f)
  template binary(f): untyped = prop(pbinary f)
  template ternary(f): untyped = prop(pternary f)
  body

template withGroup*(net: Net, name, body: untyped): untyped =
  let name = net.newGroup()
  withGroup name:
    body

proc adder*(self: Group, a, b, c: Cell) =
  ## a + b = c
  withGroup self:
    [a, b] -> binary(addNumeric) -> c
    [c, b] -> binary(subNumeric) -> a
    [c, a] -> binary(subNumeric) -> b

proc adder*(self: Net): tuple[group: Group, a, b, c: Cell] =
  self.withGroup g:
    let
      a = cell Numeric
      b = cell Numeric
      c = cell Numeric
    g.adder(a, b, c)
    (g, a, b, c)

proc multiply*(self: Group, a, b, c: Cell) =
  ## a * b = c
  withGroup self:
    [a, b] -> binary(mulNumeric) -> c
    [c, b] -> binary(divNumeric) -> a
    [c, a] -> binary(divNumeric) -> b

proc multiply*(self: Net): tuple[group: Group, a, b, c: Cell] =
  self.withGroup g:
    let
      a = cell Numeric
      b = cell Numeric
      c = cell Numeric
    g.multiply(a, b, c)
    (g, a, b, c)

type
  Tms = ref object
    all: BSet
    nogood: BSet

proc newTms*(): Tms =
  Tms(all: newBSet(), nogood: newBSet())

proc incl*(self: Tms, val: Value) =
  self.all.incl val

proc excl*(self: Tms, val: Value) =
  self.all.incl val
  self.nogood.incl val

proc good*(self: Tms): BSet =
  self.all - self.nogood

when isMainModule:

  template section(msg, body) =
    echo "\n================================"
    echo msg
    echo "================================\n"
    body

  assert Numeric is ValueLattice

  let net = newNetwork()
  net.withGroup numbers:
    let
      a = cell Numeric
      b = cell Numeric
      c = cell Numeric
      d = cell Numeric

  enable numbers
  
  numbers.adder(a, b, c)
  numbers.multiply(b, c, d)

  template printNumbers =
    echo "a: ", a
    echo "b: ", b
    echo "c: ", c
    echo "d: ", d

  section "init":
    printNumbers

  section "first run":
    a &= "[1 10]"
    b &= "7"
    run net
    printNumbers

  section "activating numbers":
    enable numbers
    run net
    printNumbers

  section "updating d":
    d &= "[98 102]"
    run net
    printNumbers