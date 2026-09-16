import std/[strformat, deques, sets]
import ../core
import ./lattice

type
  NetworkError = object of CatchableError
  ValueMerge* = proc(prev, curr: Value): Merged[Value] {.nimcall.}

  NetworkEventKind* = enum
    nekRun, nekMerge, nekExcl

  NetworkEvent* = object
    case kind*: NetworkEventKind
    of nekMerge:
      cell*: Cell
      value*: Value
    of nekRun:
      prop*: Prop
    of nekExcl:
      element*: Element

  Net* = ref object of RootObj
    cells*: HashSet[Cell]
    props*: HashSet[Prop]
    primaryEvents: Deque[NetworkEvent]
    secondaryEvents: Deque[NetworkEvent]
    running: bool
    gas: int

  Element* = ref object of RootObj
    net*: Net

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
    active*: bool

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
    fmt"Run"
  of nekExcl:
    fmt"Excl"
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

proc exclEvent(element: Element): NetworkEvent =
  NetworkEvent(kind: nekExcl, element: element)

proc mergeEvent(cell: Cell, value: Value): NetworkEvent =
  NetworkEvent(kind: nekMerge, cell: cell, value: value)

proc scheduleRun(self: Net, prop: Prop) =
  if prop in self.props:
    self.schedule runEvent(prop)

proc scheduleExcl(self: Net, element: Element) =
  self.schedule exclEvent(element)

proc scheduleMerge(self: Net, cell: Cell, value: Value) =
  if cell in self.cells:
    self.schedule mergeEvent(cell, value)

proc excl*(els: varargs[Element]) =
  for el in els:
    el.net.scheduleExcl(el)

# ================ Event Handling ================

proc add*(self: Cell, val: Value)
proc doMerge(self: Cell, val: Value)

proc doRun(self: Prop) =
  if self notin self.net.props:
    return
  var values = newSeq[Value](self.inputs.len)
  for i, cell in self.inputs:
    values[i] = cell.current
  if self.shouldRunProc(values):
    let res = self.runProc(values)
    for cell in self.outputs:
      cell.add res

method doExcl(self: Element, net: Net) {.base.} =
  discard

method doExcl(self: Cell, net: Net) =
  if self in net.cells:
    net.cells.excl self
    for prop in self.inputs:
      prop.outputs.excl self
    for prop in self.outputs:
      #[
      Note: I may change this, but with how propagators
      are, removing a propagators input will break
      the propagator, so i think removing all downstream
      propagators here is correct
      ]#
      prop.excl

method doExcl(self: Prop, net: Net) =
  if self in net.props:
    net.props.excl self
    for cell in self.inputs:
      cell.outputs.excl self
    for cell in self.outputs:
      cell.inputs.excl self

method doExcl(self: Group, net: Net) =
  for e in self.elements:
    e.doExcl(net)

proc handleEvent(self: Net, event: NetworkEvent) =
  case event.kind
  of nekRun:
    doRun(event.prop)
  of nekExcl:
    doExcl(event.element, self)
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
  while not self.stepMain:
    continue

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
    guard values.len == 3, "ternary requires 2 arguments"
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

proc activate*(groups: varargs[Group]) =
  for group in groups:
    if group.active: continue
    let net = group.net
    for prop in group.props:
      net.props.incl prop
      for cell in prop.inputs:
        cell.outputs.incl prop
      prop.run

# ================ Constructors ================

proc newNetwork*(gas = 1_000_000): Net =
  Net(gas: gas)

proc newCell*(
    self: Net, merge: ValueMerge, current: Value = null()): Cell =
  result = Cell(net: self, mergeProc: merge, current: current)
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
  Prop(
    net: self, 
    runProc: runProc, 
    shouldRunProc: shouldRunProc)

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
  self.elements.incl result

proc cell*(self: Group, merge: ValueMerge, current: Value = null()): Cell =
  result = self.net.newCell(merge, current)
  self.elements.incl result

proc cell*[T: ValueLattice](self: Group, _: type T): Cell =
  result = self.net.newCell(T)
  self.elements.incl result

proc newGroup*(self: Net): Group =
  Group(net: self)

# ================ Groups ================

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

proc difference*(self: Group, all, nogood, good: Cell) =
  ## all - nogood = good

  proc computeGood(a, b: Value): Value =
    let
      (x, y) = (BSet, Versioned[BSet]).fromValue(a, b)
    toValue Versioned[BSet](version: y.version, value: x - y.value)

  proc getValue(a: Value): Value =
    toValue Versioned[BSet].fromValue(a).value

  withGroup self:
    [all, nogood] -> binary(computeGood) -> good
    good -> unary(getValue) -> all
    nogood -> unary(getValue) -> all

proc difference*(self: Net): tuple[group: Group, all, nogood, good: Cell] =
  self.withGroup g:
    let
      all = g.cell BSet
      nogood = g.cell Versioned[BSet]
      good = g.cell Versioned[BSet]
    difference(g, all, nogood, good)
    (g, all, nogood, good)

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
    activate numbers
    run net
    printNumbers

  section "updating d":
    d &= "[0 1008]"
    run net
    printNumbers

  let tms = net.difference()
  activate tms.group

  template printTms =
    echo "\nall: ", tms.all
    echo "\nnogood: ", tms.nogood
    echo "\ngood: ", tms.good

  section "tms init":
    printTms

  section "updating all":
    tms.all &= "{foo bar (from goose)}"
    run net
    printTms

  section "updating nogood":
    tms.nogood &= "(version 2 {(from goose)})"
    run net
    printTms

  section "updating nogood again":
    tms.nogood &= "(version 3 {foo bar})"
    run net
    printTms

  section "removing tms":
    excl tms.group
    run net
    echo net