import std/[algorithm, deques, hashes, macros]

type
  Cell* = distinct int
  Rel* = distinct int
  UnaryP* = distinct int
  BinaryP* = distinct int
  NaryP* = distinct int

  MergeFn*[S,I] = proc(state: var S, info: I): bool {.nimcall.}
  UnaryFn*[S,I] = proc(a: S): I {.nimcall, noSideEffect.}
  BinaryFn*[S,I] = proc(a, b: S): I {.nimcall, noSideEffect.}
  NaryFn*[S,I] = proc(inputs: varargs[S]): I {.nimcall, noSideEffect.}

  CellData[S] = object
    state: S
    readers: seq[Rel]

  Relation[S,I] = object
    outputs: seq[Cell]
    case
    of Unary:
      unaryP: UnaryP
      unaryInput: Cell
    of Binary:
      binaryP: BinaryP
      binaryInput: tuple[a,b: Cell]
    of Nary:
      naryP: NaryP
      naryInput: seq[Cell]

  Network*[S,I] = object
    merge:     MergeFn[S,I]
    unary:     seq[UnaryFn[S,I]]
    binary:    seq[BinaryFn[S,I]]
    nary:      seq[NaryFn[S,I]]
    cells:     seq[CellData[S]]
    relations: seq[Relation[S,I]]
    scheduled: seq[bool]
    queue:     Deque[Rel]

template indexHelpers(Handle, prefix, T, value: untyped) {.dirty.} =
  proc `$`*(a: Handle): string = prefix & "-" & $a.int
  proc `==`*(a,b: Handle): bool = a.int == b.int
  proc cmp*(a,b: Handle): int = cmp(a.int, b.int)
  proc hash*(a: Handle): Hash = hash(a.int)
  proc `[]`*[S,I](self: Network[S,I], i: Handle): lent T =
    return value

indexHelpers Cell, "cell", S, self.cells[i.int].state
indexHelpers Rel, "rel", Relation[S,I], self.relations[i.int]
indexHelpers UnaryP, "unary", UnaryFn[S,I], self.unary[i.int]
indexHelpers BinaryP, "binary", BinaryFn[S,I], self.binary[i.int]
indexHelpers NaryP, "nary", NaryFn[S,I], self.nary[i.int]

proc initNetwork*[S,I](merge: MergeFn[S,I]): Network[S,I] =
  doAssert not isNil merge, "merge cannot be nil"
  Network[S,I](merge: merge)

proc def*[S,I](self: var Network[S,I], fn: UnaryFn[S,I]): UnaryP =
  doAssert not isNil(fn), "fn cannot be nil"
  self.unary.add fn
  UnaryP self.unary.high

proc def*[S,I](self: var Network[S,I], fn: BinaryFn[S,I]): BinaryP =
  doAssert not isNil(fn), "fn cannot be nil"
  self.binary.add fn
  BinaryP self.binary.high

proc def*[S,I](self: var Network[S,I], fn: NaryFn[S,I]): NaryP =
  doAssert not isNil(fn), "fn cannot be nil"
  self.nary.add fn
  NaryP self.nary.high

proc cell*[S,I](self: var Network[S,I], state: sink S): Cell =
  result = Cell(self.cells.len)
  self.cells.add CellData[S](state: state)

proc cell*[S,I](self: var Network[S,I]): Cell =
  self.cell(default(S))

iterator inputs[S,I](r: Relation[S,I]): Cell =
  case r
  of Unary(_, input):
    yield input
  of Binary(_, inputs):
    yield inputs.a
    yield inputs.b
  of Nary(_, inputs):
    for input in inputs:
      yield input

proc schedule*[S,I](self: var Network[S,I], r: Rel) =
  if not self.scheduled[r.int]:
    self.scheduled[r.int] = true
    self.queue.addLast r

proc register[S,I](self: var Network[S,I], r: sink Relation[S,I]): Rel =
  result = Rel(self.relations.len)
  for input in r.inputs:
    if result notin self.cells[input.int].readers:
      self.cells[input.int].readers.add result
  self.relations.add r
  self.scheduled.add false
  self.schedule result

proc relate*[S,I](self: var Network[S,I],
                  p: UnaryP, a,b: Cell): Rel =
  let r: Relation[S,I] = Unary(
    unaryP: p,
    unaryInput: a,
    outputs: @[b])
  self.register r

proc feedback*[S,I](self: var Network[S,I], p: UnaryP, c: Cell): Rel =
  self.relate(p, c, c)

proc relate*[S,I](self: var Network[S,I],
                  p: BinaryP, a,b,c: Cell): Rel =
  let r: Relation[S,I] = Binary(
      binaryP: p,
      binaryInput: (a,b),
      outputs: @[c])
  self.register r

proc relate*[S,I](self: var Network[S,I],
                  p: NaryP,
                  inputs: varargs[Cell], output: Cell): Rel =
  let r: Relation[S,I] = Nary(
      naryP: p,
      naryInput: @inputs,
      outputs: @[output])
  self.register r

proc fanout*[S,I](self: var Network[S,I], r: Rel, outputs: varargs[Cell]) =
  var changed = false
  for each in outputs:
    let i = self.relations[r.int].outputs.lowerBound(each, cmp)
    if i == self.relations[r.int].outputs.len or self.relations[r.int].outputs[i] != each:
      self.relations[r.int].outputs.insert(each, i)
      changed = true
  if changed:
    self.schedule r

proc put*[S,I](self: var Network[S,I], c: Cell, info: I): bool {.discardable.} =
  result = self.merge(self.cells[c.int].state, info)
  if result:
    for r in self.cells[c.int].readers:
      self.schedule r

proc put*[S,I](self: var Network[S,I],
               forms: openArray[(Cell, I)]): bool {.discardable.} =
  for f in forms:
    if put(self, f[0], f[1]):
      result = true

proc pending*[S,I](self: Network[S,I]): int =
  self.queue.len

proc step*[S,I](self: var Network[S,I]): bool {.discardable.} =
  if self.queue.len == 0:
    return false
  let id = self.queue.popFirst()
  # Feedback must be able to schedule this relation during its own turn.
  self.scheduled[id.int] = false

  let r = self.relations[id.int]
  let info = case r
    of Unary(p, input):
      self[p](self[input])
    of Binary(p, inputs):
      self[p](self[inputs.a], self[inputs.b])
    of Nary(p, inputs):
      var states = newSeq[S](inputs.len)
      for i, input in inputs:
        states[i] = self[input]
      self[p](states)
  for output in r.outputs:
    self.put(output, info)
  true

proc run*[S,I](self: var Network[S,I], steps = high(int)): int {.discardable.} =
  while result < steps and self.step():
    inc result

proc buildCellBindings(net, names: NimNode): NimNode =
  result = newStmtList()
  for name in names:
    result.add quote do:
      let `name` = `net`.cell

macro cells*(net: Network, names: varargs[untyped]) =
  result = buildCellBindings(net, names)

when isMainModule:

  type
    CellMode = enum cMin, cMax
    State = object
      mode: CellMode
      n: int

    Info = object
      case
      of Merge:
        n: int
      of ChangeMode:
        mode: CellMode

  proc mergeMax(state: var State, info: Info): bool =
    case info
    of Merge(n):
      case state.mode
      of cMin:
        if n < state.n:
          state.n = n
          return true
      of cMax:
        if n > state.n:
          state.n = n
          return true
    of ChangeMode(m):
      state.mode = m
      return true

  proc adder(a,b: State): Info =
    Merge(n: a.n + b.n)

  var net = initNetwork(mergeMax)

  let add = net.def adder

  net.cells a,b,c,d

  let r = net.relate(add, a, b, c)
  net.fanout(r, d)

  net.put {
    a: ChangeMode(mode: cMax),
    c: ChangeMode(mode: cMax),
    a: Merge(n: 2),
    b: Merge(n: -5)
  }

  echo "run: ", net.run()
  echo net[c], " ", net[d]

  net.put(b, Merge(n: 5))
  net.run()
  echo "run: ", net.run()
  echo net[c], " ", net[d]
