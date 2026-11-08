import std/strformat
import ./ce

type
  Patkind = enum
    pkEmpty, pkOne, pkCapture, pkCat, pkAlt, pkOpt, pkStar, pkPlus

  Pat* {.acyclic.} = ref object
    case kind: Patkind
    of pkEmpty:
      discard
    of pkOne:
      kinds: set[Kind]
      mark: Option[bool]
      members: Pat
    of pkCapture, pkOpt, pkStar, pkPlus:
      m: Pat
    of pkCat, pkAlt:
      a, b: Pat

  Op = enum
    opTest, opStep, opInside, opSplit, opJump, opOpen, opClose, opMatch

  Inst = object
    case op: Op
    of opTest:
      kinds: set[Kind]
      mark: Option[bool]
    of opInside:
      next: int
    of opSplit:
      first, second: int
    of opJump:
      to: int
    of opOpen, opClose:
      slot: int
    of opStep, opMatch:
      discard

  Prog* = ref object
    insts: seq[Inst]
    slots: int

  Span* = object
    path*: seq[int]
    lo*, hi*: int

  Mode = enum
    whole, leftmost, leftmostNonempty

  Thread = object
    pc: int
    spans: seq[Option[Span]]

  Threads = object
    list: seq[Thread]
    seen: seq[int]
    gen: int

  Vm[T] = object
    prog: Prog
    frame: T
    path: seq[int]
    stop: int

  StepKind = enum
    skEach, skWhere, skGaps, skUnless, skDown, skWalk, skBranch

  Step = object
    case kind: StepKind
    of skEach, skWhere:
      prog: Prog
      slot: int
    of skGaps, skUnless:
      excluded: Prog
    of skDown, skWalk:
      discard
    of skBranch:
      branches: seq[Command]

  Command* = ref object
    steps: seq[Step]

  Selection* = object
    span*: Span
    captures*: seq[Option[Span]]

  Pending = object
    selection: Selection
    command: Command
    at: int

refuseWith BasslineError

const
  everyKind = {bNil .. bSet}
  frames = slotted + keyed

func one*(kinds = everyKind, mark = anyMark): Pat =
  Pat(kind: pkOne, kinds: kinds, mark: mark)

func frame*(members: Pat, kinds = frames, mark = anyMark): Pat =
  guard kinds <= frames, "only a frame has members to match"
  Pat(kind: pkOne, kinds: kinds, mark: mark, members: members)

func capture*(m: Pat): Pat =
  Pat(kind: pkCapture, m: m)

func cat*(ps: varargs[Pat]): Pat =
  if ps.len == 0:
    return Pat(kind: pkEmpty)
  result = ps[0]
  for i in 1 ..< ps.len:
    result = Pat(kind: pkCat, a: result, b: ps[i])

func alt*(ps: varargs[Pat]): Pat =
  guard ps.len > 0, "alt needs a pattern to choose"
  result = ps[0]
  for i in 1 ..< ps.len:
    result = Pat(kind: pkAlt, a: result, b: ps[i])

func opt*(m: Pat): Pat =
  Pat(kind: pkOpt, m: m)

func star*(m: Pat): Pat =
  Pat(kind: pkStar, m: m)

func plus*(m: Pat): Pat =
  Pat(kind: pkPlus, m: m)

proc `$`*(p: Pat): string =
  case p.kind
  of pkEmpty:
    "()"
  of pkOne:
    let mark =
      if p.mark.isNone: "any"
      elif p.mark.get: "marked"
      else: "unmarked"
    var kinds = $p.kinds
    if p.kinds.len == 1:
      for k in p.kinds:
        kinds = $k
    if p.members.isNil: fmt"{mark}-{kinds}"
    else: fmt"{mark}-{kinds}<{p.members}>"
  of pkCapture:
    fmt"({p.m})"
  of pkCat:
    fmt"{p.a} THEN {p.b}"
  of pkAlt:
    fmt"[{p.a} OR {p.b}]"
  of pkOpt:
    fmt"{p.m}?"
  of pkStar:
    fmt"{p.m}*"
  of pkPlus:
    fmt"{p.m}+"

proc compilePostfix*(str: string): Pat =
  var
    stack: seq[Pat]
    kinds: set[Kind]
    mark = anyMark

  template unary(op: char, make) =
    guard stack.len >= 1, op & " needs a pattern"
    stack.add stack.pop.make

  template binary(op: char, make) =
    guard stack.len >= 2, op & " needs two patterns"
    let b = stack.pop
    stack.add make(stack.pop, b)

  for c in str:
    case c
    of '-': kinds.incl bNil
    of 'n': kinds.incl bNum
    of 't': kinds.incl bText
    of 's': kinds.incl bSym
    of 'b': kinds.incl bBytes
    of 'L': kinds.incl bList
    of 'R': kinds.incl bRec
    of 'D': kinds.incl bDict
    of 'S': kinds.incl bSet
    of '!': mark = marked
    of '~': mark = unmarked
    of '.':
      stack.add one(if kinds == {}: everyKind else: kinds, mark)
      kinds = {}
      mark = anyMark
    of '*': unary(c, star)
    of '+': unary(c, plus)
    of '?': unary(c, opt)
    of ',': binary(c, cat)
    of '|': binary(c, alt)
    of ' ', '\n', '\t': discard
    else: refuse "unsupported rule: " & c

  guard stack.len == 1, "must compile to one pattern, got " & $stack.len
  stack[0]

proc emit(prog: Prog, p: Pat) =
  template here: int = prog.insts.len
  case p.kind
  of pkEmpty:
    discard
  of pkOne:
    prog.insts.add Inst(op: opTest, kinds: p.kinds, mark: p.mark)
    if p.members.isNil:
      prog.insts.add Inst(op: opStep)
    else:
      let inside = here
      prog.insts.add Inst(op: opInside)
      prog.emit p.members
      prog.insts.add Inst(op: opMatch)
      prog.insts[inside].next = here
  of pkCapture:
    let slot = prog.slots
    inc prog.slots
    prog.insts.add Inst(op: opOpen, slot: slot)
    prog.emit p.m
    prog.insts.add Inst(op: opClose, slot: slot)
  of pkCat:
    prog.emit p.a
    prog.emit p.b
  of pkAlt:
    let split = here
    prog.insts.add Inst(op: opSplit, first: split + 1)
    prog.emit p.a
    let jump = here
    prog.insts.add Inst(op: opJump)
    prog.insts[split].second = here
    prog.emit p.b
    prog.insts[jump].to = here
  of pkOpt:
    let split = here
    prog.insts.add Inst(op: opSplit, first: split + 1)
    prog.emit p.m
    prog.insts[split].second = here
  of pkStar:
    let split = here
    prog.insts.add Inst(op: opSplit, first: split + 1)
    prog.emit p.m
    prog.insts.add Inst(op: opJump, to: split)
    prog.insts[split].second = here
  of pkPlus:
    let start = here
    prog.emit p.m
    prog.insts.add Inst(op: opSplit, first: start, second: here + 1)

proc compile*(p: Pat): Prog =
  result = Prog(slots: 1)
  result.insts.add Inst(op: opOpen, slot: 0)
  result.emit p
  result.insts.add Inst(op: opClose, slot: 0)
  result.insts.add Inst(op: opMatch)

func initThreads(prog: Prog): Threads =
  Threads(seen: newSeq[int](prog.insts.len), gen: 1)

func clear(threads: var Threads) =
  threads.list.setLen 0
  inc threads.gen

proc add[T](vm: Vm[T], threads: var Threads, pc, pos: int, spans: seq[Option[Span]]) =
  if threads.seen[pc] == threads.gen:
    return
  threads.seen[pc] = threads.gen
  let inst = vm.prog.insts[pc]
  case inst.op
  of opJump:
    vm.add(threads, inst.to, pos, spans)
  of opSplit:
    vm.add(threads, inst.first, pos, spans)
    vm.add(threads, inst.second, pos, spans)
  of opOpen:
    var opened = spans
    opened[inst.slot] = some Span(path: vm.path, lo: pos, hi: pos)
    vm.add(threads, pc + 1, pos, opened)
  of opClose:
    var closed = spans
    closed[inst.slot].get.hi = pos
    vm.add(threads, pc + 1, pos, closed)
  of opTest:
    if pos < vm.stop and vm.frame.getChild(pos).isKind(inst.kinds, inst.mark):
      vm.add(threads, pc + 1, pos, spans)
  of opStep, opInside, opMatch:
    threads.list.add Thread(pc: pc, spans: spans)

proc run[T](vm: Vm[T], entry: int, spans: seq[Option[Span]], mode: Mode, start: int): Option[seq[Option[Span]]] =
  var
    now = initThreads(vm.prog)
    next = initThreads(vm.prog)
  for pos in start .. vm.stop:
    if result.isNone and (mode != whole or pos == start):
      vm.add(now, entry, pos, spans)
    for thread in now.list:
      let inst = vm.prog.insts[thread.pc]
      case inst.op
      of opStep:
        vm.add(next, thread.pc + 1, pos + 1, thread.spans)
      of opInside:
        let
          member = vm.frame.getChild(pos)
          inner = Vm[T](prog: vm.prog, frame: member, path: vm.path & pos, stop: member.len)
          found = inner.run(thread.pc + 1, thread.spans, whole, 0)
        if found.isSome:
          vm.add(next, inst.next, pos + 1, found.get)
      of opMatch:
        let accepted =
          case mode
          of whole: pos == vm.stop
          of leftmost: true
          of leftmostNonempty: pos > thread.spans[0].get.lo
        if accepted:
          result = some thread.spans
          break
      else:
        discard
    if next.list.len == 0 and (result.isSome or mode == whole):
      break
    swap now, next
    next.clear

proc scan[T](prog: Prog, frame: T, span: Span, mode: Mode, start: int): Option[seq[Option[Span]]] =
  let vm = Vm[T](prog: prog, frame: frame, path: span.path, stop: span.hi)
  vm.run(0, newSeq[Option[Span]](prog.slots), mode, start)

iterator fits[T](prog: Prog, frame: T, span: Span): seq[Option[Span]] =
  var pos = span.lo
  while pos < span.hi:
    let found = prog.scan(frame, span, leftmostNonempty, pos)
    if found.isNone:
      break
    yield found.get
    pos = found.get[0].get.hi

proc match*[T: Walkable](prog: Prog, v: T): Option[seq[Option[Span]]] =
  if v.isKind(frames):
    result = prog.scan(v, Span(hi: v.len), whole, 0)

proc find*[T: Walkable](prog: Prog, v: T, start = 0): Option[seq[Option[Span]]] =
  guard start in 0 .. v.len, "no place " & $start & " to search from"
  if v.isKind(frames):
    result = prog.scan(v, Span(hi: v.len), leftmost, start)

proc at[T](v: T, path: seq[int]): T =
  result = v
  for i in path:
    result = result.getChild(i)

proc `[]`*[T: Walkable](v: T, s: Span): seq[T] =
  let frame = v.at(s.path)
  for i in s.lo ..< s.hi:
    result.add frame.getChild(i)

func then(c: Command, step: Step): Command =
  Command(steps: c.steps & step)

proc each*(c: Command, p: Pat, slot = 0): Command =
  c.then Step(kind: skEach, prog: p.compile, slot: slot)

proc where*(c: Command, p: Pat, slot = 0): Command =
  c.then Step(kind: skWhere, prog: p.compile, slot: slot)

proc gaps*(c: Command, p: Pat): Command =
  c.then Step(kind: skGaps, excluded: p.compile)

proc unless*(c: Command, p: Pat): Command =
  c.then Step(kind: skUnless, excluded: p.compile)

func down*(c: Command): Command =
  c.then Step(kind: skDown)

func walk*(c: Command): Command =
  c.then Step(kind: skWalk)

func branch*(c: Command, branches: varargs[Command]): Command =
  c.then Step(kind: skBranch, branches: @branches)

proc each*(p: Pat, slot = 0): Command =
  Command().each(p, slot)

proc where*(p: Pat, slot = 0): Command =
  Command().where(p, slot)

proc gaps*(p: Pat): Command =
  Command().gaps(p)

proc unless*(p: Pat): Command =
  Command().unless(p)

func down*(): Command =
  Command().down

func walk*(): Command =
  Command().walk

func narrowed(selection: Selection, lo, hi: int): Selection =
  Selection(span: Span(path: selection.span.path, lo: lo, hi: hi), captures: selection.captures)

proc expand[T](v: T, item: Pending): seq[Pending] =
  let
    step = item.command.steps[item.at]
    span = item.selection.span
    frame = v.at(span.path)

  template onward(found: Selection): Pending =
    Pending(selection: found, command: item.command, at: item.at + 1)

  template inside(i: int): Selection =
    Selection(span: Span(path: span.path & i, hi: frame.getChild(i).len), captures: item.selection.captures)

  case step.kind
  of skEach:
    for fit in step.prog.fits(frame, span):
      if fit[step.slot].isSome:
        result.add onward(Selection(span: fit[step.slot].get, captures: fit))
  of skWhere:
    let fit = step.prog.scan(frame, span, whole, span.lo)
    if fit.isSome and fit.get[step.slot].isSome:
      result.add onward(Selection(span: fit.get[step.slot].get, captures: fit.get))
  of skGaps:
    var lo = span.lo
    for fit in step.excluded.fits(frame, span):
      if fit[0].get.lo > lo:
        result.add onward(item.selection.narrowed(lo, fit[0].get.lo))
      lo = fit[0].get.hi
    if span.hi > lo:
      result.add onward(item.selection.narrowed(lo, span.hi))
  of skUnless:
    if step.excluded.scan(frame, span, whole, span.lo).isNone:
      result.add onward(item.selection)
  of skDown:
    for i in span.lo ..< span.hi:
      if frame.getChild(i).isKind(frames):
        result.add onward(inside(i))
  of skWalk:
    result.add onward(item.selection)
    for i in span.lo ..< span.hi:
      if frame.getChild(i).isKind(frames):
        result.add Pending(selection: inside(i), command: item.command, at: item.at)
  of skBranch:
    let rest = item.command.steps[item.at + 1 .. ^1]
    for sub in step.branches:
      result.add Pending(selection: item.selection, command: Command(steps: sub.steps & rest))

iterator selections*[T: Walkable](c: Command, v: T): Selection =
  var pending: seq[Pending]
  if v.isKind(frames):
    pending.add Pending(selection: Selection(span: Span(hi: v.len)), command: c)
  while pending.len > 0:
    let item = pending.pop
    if item.at == item.command.steps.len:
      yield item.selection
    else:
      let expanded = v.expand(item)
      for i in countdown(expanded.high, 0):
        pending.add expanded[i]