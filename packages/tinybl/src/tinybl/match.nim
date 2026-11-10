import std/[algorithm, sequtils, sets, strformat, strutils, sugar, tables]
import petit_parser
import ./[ce, text, values]

type
  Patkind = enum
    pkEmpty, pkOne, pkCapture, pkCat, pkAlt, pkOpt, pkStar, pkPlus

  PayloadTest = enum
    ptAny, ptExact, ptPrefix, ptSuffix, ptInfix

  Pat* {.acyclic.} = ref object
    case kind: Patkind
    of pkEmpty:
      discard
    of pkOne:
      kinds: set[Kind]
      mark: Option[bool]
      test: PayloadTest
      payload: string
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
      test: PayloadTest
      payload: string
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

  AddressKind = enum
    adDot, adStart, adEnd, adMember, adSearch, adSpan, adThen, adAfter, adBefore, adInto, adOut

  Address* {.acyclic.} = ref object
    case kind: AddressKind
    of adDot, adStart, adEnd:
      discard
    of adMember:
      n: int
    of adSearch:
      prog: Prog
      slot: int
      backward: bool
    of adSpan, adThen, adAfter, adBefore, adInto:
      left, right: Address
    of adOut:
      inner: Address

  StepKind = enum
    skEach, skWhere, skGaps, skUnless, skDown, skWalk, skBranch, skAddress,
    skPrint, skChange, skInsert, skAppend, skDelete, skSubstitute, skMove, skCopy

  Step = object
    case kind: StepKind
    of skEach, skWhere:
      prog: Prog
      slot: int
    of skGaps, skUnless:
      excluded: Prog
    of skDown, skWalk, skPrint, skDelete:
      discard
    of skBranch:
      branches: seq[Command]
    of skAddress:
      address: Address
    of skChange, skInsert, skAppend:
      replacement: seq[string]
    of skSubstitute:
      pattern: Prog
      substitution: seq[string]
      everyFit: bool
    of skMove, skCopy:
      target: Address

  Command* = ref object
    steps: seq[Step]

  Selection* = object
    span*: Span
    captures*: seq[Option[Span]]

  Pending = object
    selection: Selection
    command: Command
    at: int

  Change[T] = object
    path: seq[int]
    lo, hi: int
    members: seq[T]
    order: int

refuseWith BasslineError

const
  everyKind = {bNil .. bSet}
  frames = slotted + keyed
  terminal = {skPrint, skChange, skInsert, skAppend, skDelete, skSubstitute, skMove, skCopy}

func one*(kinds = everyKind, mark = anyMark): Pat =
  Pat(kind: pkOne, kinds: kinds, mark: mark)

func frame*(members: Pat, kinds = frames, mark = anyMark): Pat =
  guard kinds <= frames, "only a frame has members to match"
  Pat(kind: pkOne, kinds: kinds, mark: mark, members: members)

func tested(p: Pat, test: PayloadTest, payload: string, kinds: set[Kind]): Pat =
  guard p.kind == pkOne and p.members.isNil and p.test == ptAny,
    "only a member not yet tested is tested by its payload"
  guard p.kinds <= kinds, "only " & $kinds & " are tested so"
  Pat(kind: pkOne, kinds: p.kinds, mark: p.mark, test: test, payload: payload)

func exactly*(p: Pat, payload: string): Pat =
  p.tested(ptExact, payload, {bNum, bText, bSym, bBytes})

func startingWith*(p: Pat, prefix: string): Pat =
  p.tested(ptPrefix, prefix, {bText, bSym, bBytes})

func endingWith*(p: Pat, suffix: string): Pat =
  p.tested(ptSuffix, suffix, {bText, bSym, bBytes})

func containing*(p: Pat, infix: string): Pat =
  p.tested(ptInfix, infix, {bText, bSym, bBytes})

func withMark(p: Pat, mark: Option[bool]): Pat =
  case p.kind
  of pkOne:
    Pat(kind: pkOne, kinds: p.kinds, mark: mark, test: p.test, payload: p.payload,
      members: p.members)
  else:
    p

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

func takesNothing(p: Pat): bool =
  case p.kind
  of pkEmpty, pkOpt, pkStar: true
  of pkOne: false
  of pkCapture, pkPlus: p.m.takesNothing
  of pkCat: p.a.takesNothing and p.b.takesNothing
  of pkAlt: p.a.takesNothing or p.b.takesNothing

func star*(m: Pat): Pat =
  guard not m.takesNothing, "a loop's body must take a member"
  Pat(kind: pkStar, m: m)

func plus*(m: Pat): Pat =
  guard not m.takesNothing, "a loop's body must take a member"
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
    let test =
      case p.test
      of ptAny: ""
      of ptExact: " " & p.payload.escape
      of ptPrefix: " " & p.payload.escape & "…"
      of ptSuffix: " …" & p.payload.escape
      of ptInfix: " …" & p.payload.escape & "…"
    if p.members.isNil: fmt"{mark}-{kinds}{test}"
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

proc emit(prog: Prog, p: Pat) =
  template here: int = prog.insts.len
  case p.kind
  of pkEmpty:
    discard
  of pkOne:
    prog.insts.add Inst(op: opTest, kinds: p.kinds, mark: p.mark, test: p.test, payload: p.payload)
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

proc payloadOf[T](v: T): string =
  case v.kind
  of bNum: v.numStr
  of bText: v.textVal
  of bSym: v.symVal
  of bBytes: v.bytesVal
  else: ""

proc passes[T](v: T, inst: Inst): bool =
  if not v.isKind(inst.kinds, inst.mark):
    return false
  case inst.test
  of ptAny: true
  of ptExact: v.payloadOf == inst.payload
  of ptPrefix: v.payloadOf.startsWith(inst.payload)
  of ptSuffix: v.payloadOf.endsWith(inst.payload)
  of ptInfix: inst.payload in v.payloadOf

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
    if pos < vm.stop and vm.frame.getChild(pos).passes(inst):
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

proc frameAt[T](v: T, path: seq[int]): T =
  result = v
  for i in path:
    result = result.getChild(i)

proc `[]`*[T: Walkable](v: T, s: Span): seq[T] =
  let frame = v.frameAt(s.path)
  for i in s.lo ..< s.hi:
    result.add frame.getChild(i)

proc searchForward[T](prog: Prog, frame: T, path: seq[int], start: int): Option[seq[Option[Span]]] =
  let whole = Span(path: path, hi: frame.len)
  result = prog.scan(frame, whole, leftmostNonempty, start)
  if result.isNone and start > 0:
    result = prog.scan(frame, whole, leftmostNonempty, 0)

proc searchBackward[T](prog: Prog, frame: T, path: seq[int], stop: int): Option[seq[Option[Span]]] =
  for fit in prog.fits(frame, Span(path: path, hi: stop)):
    result = some fit
  if result.isNone and stop < frame.len:
    for fit in prog.fits(frame, Span(path: path, hi: frame.len)):
      result = some fit

func searches(a: Address): bool =
  case a.kind
  of adDot, adStart, adEnd, adMember: false
  of adSearch: true
  of adSpan, adThen, adAfter, adBefore, adInto: a.left.searches or a.right.searches
  of adOut: a.inner.searches

proc resolve[T](a: Address, v: T, dot: Selection): Option[Selection]

proc found[T](a: Address, v: T, path: seq[int], fit: Option[seq[Option[Span]]]): Option[Selection] =
  if fit.isSome and fit.get[a.slot].isSome:
    result = some Selection(span: fit.get[a.slot].get, captures: fit.get)

proc resolveFrom[T](a: Address, v: T, base: Selection, forward: bool): Option[Selection] =
  let
    path = base.span.path
    frame = v.frameAt(path)
  case a.kind
  of adMember:
    let (lo, hi) =
      if a.n == 0 and forward: (base.span.hi, base.span.hi)
      elif a.n == 0: (base.span.lo, base.span.lo)
      elif forward: (base.span.hi + a.n - 1, base.span.hi + a.n)
      else: (base.span.lo - a.n, base.span.lo - a.n + 1)
    if lo >= 0 and hi <= frame.len:
      result = some Selection(span: Span(path: path, lo: lo, hi: hi), captures: base.captures)
  of adSearch:
    let start = if forward: base.span.hi else: base.span.lo
    result =
      if forward == a.backward: a.found(v, path, a.prog.searchBackward(frame, path, start))
      else: a.found(v, path, a.prog.searchForward(frame, path, start))
  else:
    result = a.resolve(v, base)

proc resolve[T](a: Address, v: T, dot: Selection): Option[Selection] =
  let
    path = dot.span.path
    frame = v.frameAt(path)

  template within(first, second: Option[Selection], kept: untyped): Option[Selection] =
    if first.isSome and second.isSome and first.get.span.path == second.get.span.path and
        first.get.span.lo <= second.get.span.hi:
      some Selection(
        span: Span(path: first.get.span.path, lo: first.get.span.lo, hi: second.get.span.hi),
        captures: kept)
    else:
      none(Selection)

  case a.kind
  of adDot:
    some dot
  of adStart:
    some Selection(span: Span(path: path), captures: dot.captures)
  of adEnd:
    some Selection(span: Span(path: path, lo: frame.len, hi: frame.len), captures: dot.captures)
  of adMember:
    if a.n == 0:
      some Selection(span: Span(path: path), captures: dot.captures)
    elif a.n <= frame.len:
      some Selection(span: Span(path: path, lo: a.n - 1, hi: a.n), captures: dot.captures)
    else:
      none(Selection)
  of adSearch:
    if a.backward: a.found(v, path, a.prog.searchBackward(frame, path, dot.span.lo))
    else: a.found(v, path, a.prog.searchForward(frame, path, dot.span.hi))
  of adSpan:
    let
      first = a.left.resolve(v, dot)
      second = a.right.resolve(v, dot)
    within(first, second, if a.right.searches: second.get.captures else: first.get.captures)
  of adThen:
    let first = a.left.resolve(v, dot)
    if first.isNone:
      none(Selection)
    else:
      let second = a.right.resolve(v, first.get)
      within(first, second, second.get.captures)
  of adAfter, adBefore:
    let first = a.left.resolve(v, dot)
    if first.isNone: none(Selection)
    else: a.right.resolveFrom(v, first.get, forward = a.kind == adAfter)
  of adInto:
    let first = a.left.resolve(v, dot)
    if first.isNone or first.get.span.hi - first.get.span.lo != 1:
      none(Selection)
    else:
      let span = first.get.span
      if not v.frameAt(span.path).getChild(span.lo).isKind(frames):
        return none(Selection)
      a.right.resolve(v, Selection(span: Span(path: span.path & span.lo), captures: first.get.captures))
  of adOut:
    let inner = a.inner.resolve(v, dot)
    if inner.isNone or inner.get.span.path.len == 0:
      none(Selection)
    else:
      let way = inner.get.span.path
      some Selection(span: Span(path: way[0 ..^ 2], lo: way[^1], hi: way[^1] + 1),
        captures: inner.get.captures)

func then(c: Command, step: Step): Command =
  guard c.steps.len == 0 or c.steps[^1].kind notin terminal,
    "nothing follows an edit or a print"
  Command(steps: c.steps & step)

proc compileFor(p: Pat, slot: int): Prog =
  result = p.compile
  guard slot in 0 ..< result.slots,
    "no slot " & $slot & " in a pattern of " & $result.slots

proc each*(c: Command, p: Pat, slot = 0): Command =
  c.then Step(kind: skEach, prog: p.compileFor(slot), slot: slot)

proc where*(c: Command, p: Pat, slot = 0): Command =
  c.then Step(kind: skWhere, prog: p.compileFor(slot), slot: slot)

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

func at*(c: Command, address: Address): Command =
  c.then Step(kind: skAddress, address: address)

func print*(c: Command): Command =
  c.then Step(kind: skPrint)

proc change*[T: Walkable](c: Command, replacement: varargs[T]): Command =
  c.then Step(kind: skChange, replacement: replacement.mapIt(it.ce))

proc insert*[T: Walkable](c: Command, replacement: varargs[T]): Command =
  c.then Step(kind: skInsert, replacement: replacement.mapIt(it.ce))

proc append*[T: Walkable](c: Command, replacement: varargs[T]): Command =
  c.then Step(kind: skAppend, replacement: replacement.mapIt(it.ce))

func delete*(c: Command): Command =
  c.then Step(kind: skDelete)

proc substitute*[T: Walkable](c: Command, p: Pat, replacement: openArray[T], everyFit = false): Command =
  c.then Step(kind: skSubstitute, pattern: p.compile, substitution: replacement.mapIt(it.ce),
    everyFit: everyFit)

func move*(c: Command, target: Address): Command =
  c.then Step(kind: skMove, target: target)

func copy*(c: Command, target: Address): Command =
  c.then Step(kind: skCopy, target: target)

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

func at*(address: Address): Command =
  Command().at(address)

func narrowed(selection: Selection, lo, hi: int): Selection =
  Selection(span: Span(path: selection.span.path, lo: lo, hi: hi), captures: selection.captures)

proc expand[T](v: T, item: Pending): seq[Pending] =
  let
    step = item.command.steps[item.at]
    span = item.selection.span
    frame = v.frameAt(span.path)

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
  of skAddress:
    let found = step.address.resolve(v, item.selection)
    if found.isSome:
      result.add onward(found.get)
  of skPrint, skChange, skInsert, skAppend, skDelete, skSubstitute, skMove, skCopy:
    discard

proc started[T](c: Command, v: T, dot: Option[Selection]): seq[Pending] =
  if v.isKind(frames):
    result.add Pending(selection: dot.get(Selection(span: Span(hi: v.len))), command: c)

proc advance[T](v: T, pending: var seq[Pending]): Option[Pending] =
  while pending.len > 0:
    let item = pending.pop
    if item.at == item.command.steps.len or item.command.steps[item.at].kind in terminal:
      return some item
    let expanded = v.expand(item)
    for i in countdown(expanded.high, 0):
      pending.add expanded[i]

func ended(item: Pending): bool =
  item.at == item.command.steps.len

iterator selections*[T: Walkable](c: Command, v: T, dot = none(Selection)): Selection =
  var pending = c.started(v, dot)
  while true:
    let item = v.advance(pending)
    if item.isNone:
      break
    if item.get.ended or item.get.command.steps[item.get.at].kind == skPrint:
      yield item.get.selection

proc decoded[T](bytes: string): T =
  var
    reader: TypeReader[T]
    pos = 0
  guard reader.readCE(bytes, pos) and pos == bytes.len, "a replacement is one whole value"
  move reader.value

proc framed[T](members: sink seq[T], kind: Kind, mark: bool): T =
  mixin buildFrame
  case kind
  of bSet:
    members.sort((a, b: T) => basslineCmp(a, b))
    for i in 1 ..< members.len:
      guard basslineCmp(members[i - 1], members[i]) != 0, "a set holds each member once"
  of bDict:
    guard members.len mod 2 == 0, "a dict holds a value for each key"
    var entries = collect:
      for i in countup(0, members.high, 2):
        (members[i], members[i + 1])
    entries.sort((a, b: (T, T)) => basslineCmp(a[0], b[0]))
    for i in 1 ..< entries.len:
      guard basslineCmp(entries[i - 1][0], entries[i][0]) != 0, "a dict holds each key once"
    members = entries.mapIt(@[it[0], it[1]]).concat
  else:
    discard
  T.buildFrame(members, kind, mark)

proc spliced[T](v: T, part: T, selection: Selection): seq[T] =
  if part.isKind(bSym, unmarked) and part.symVal.len > 1 and part.symVal[0] == '$' and
      part.symVal[1 .. ^1].allCharsInSet(Digits):
    let n = part.symVal[1 .. ^1].parseInt
    if n == 0:
      return v[selection.span]
    guard n < selection.captures.len, "no capture " & part.symVal & " to put"
    if selection.captures[n].isSome:
      result = v[selection.captures[n].get]
  elif part.isKind(frames):
    var members: seq[T]
    for child in part.children:
      members.add v.spliced(child, selection)
    result = @[framed(members, part.kind, part.mark)]
  else:
    result = @[part]

proc filled[T](v: T, replacement: seq[string], selection: Selection): seq[T] =
  for bytes in replacement:
    result.add v.spliced(decoded[T](bytes), selection)

proc changesOf[T](v: T, c: Command, dot: Option[Selection]): seq[Change[T]] =
  proc put(changes: var seq[Change[T]], path: seq[int], lo, hi: int, members: seq[T]) =
    changes.add Change[T](path: path, lo: lo, hi: hi, members: members, order: changes.len)

  var pending = c.started(v, dot)
  while true:
    let reached = v.advance(pending)
    if reached.isNone:
      break
    let item = reached.get
    if item.ended:
      continue
    let
      step = item.command.steps[item.at]
      selection = item.selection
      span = selection.span
    case step.kind
    of skChange:
      result.put(span.path, span.lo, span.hi, v.filled(step.replacement, selection))
    of skInsert:
      result.put(span.path, span.lo, span.lo, v.filled(step.replacement, selection))
    of skAppend:
      result.put(span.path, span.hi, span.hi, v.filled(step.replacement, selection))
    of skDelete:
      result.put(span.path, span.lo, span.hi, @[])
    of skSubstitute:
      for fit in step.pattern.fits(v.frameAt(span.path), span):
        let fitted = Selection(span: fit[0].get, captures: fit)
        result.put(span.path, fitted.span.lo, fitted.span.hi, v.filled(step.substitution, fitted))
        if not step.everyFit:
          break
    of skMove, skCopy:
      let target = step.target.resolve(v, selection)
      if target.isSome:
        let place = target.get.span
        result.put(place.path, place.hi, place.hi, v[span])
        if step.kind == skMove:
          result.put(span.path, span.lo, span.hi, @[])
    else:
      discard

proc applied[T](frame: T, path: seq[int], changes: Table[seq[int], seq[Change[T]]],
    touched: HashSet[seq[int]]): T =
  let here = changes.getOrDefault(path)
  if frame.isKind(bDict):
    for change in here:
      guard (change.hi - change.lo) mod 2 == change.members.len mod 2,
        "a change in a dict keeps its keys and values in pairs"
  var
    members: seq[T]
    i = 0
    next = 0
  while true:
    while next < here.len and here[next].lo == i:
      members.add here[next].members
      i = here[next].hi
      inc next
    if i >= frame.len:
      break
    let child = frame.getChild(i)
    members.add(if (path & i) in touched: child.applied(path & i, changes, touched) else: child)
    inc i
  framed(members, frame.kind, frame.mark)

proc edit*[T: Walkable](v: T, c: Command, dot = none(Selection)): T =
  var
    changes = v.changesOf(c, dot)
    byPath: Table[seq[int], seq[Change[T]]]
    touched: HashSet[seq[int]]
  if changes.len == 0:
    return v
  changes.sort((a, b: Change[T]) => cmp((a.lo, a.hi, a.order), (b.lo, b.hi, b.order)))
  for change in changes:
    byPath.mgetOrPut(change.path, @[]).add change
    for depth in 0 .. change.path.len:
      touched.incl change.path[0 ..< depth]
  for path, here in byPath:
    for i in 1 ..< here.len:
      let (before, after) = (here[i - 1], here[i])
      guard after.lo >= before.hi, "changes overlap at " & $path & " " & $after.lo
    for depth in 0 ..< path.len:
      for outer in byPath.getOrDefault(path[0 ..< depth]):
        guard not (outer.lo <= path[depth] and path[depth] < outer.hi),
          "a change inside one that replaces it, at " & $path
  v.applied(@[], byPath, touched)

proc patternGrammar(delimiter = '\0'): TextParser[Pat] =
  const
    symbolCharacters = {'\x21' .. '\xff'} - {'[', ']', '{', '}', '(', ')', ':', '\'', '"', ';',
      '!', '~', '*', '+', '?', '|', '<', '>', '$', '#', '.', '/', ','}
  let
    ws = chars(" \t\n\r", "whitespace")
    whole = undefined[string, Pat]("pattern")
    term = undefined[string, Pat]("term")
    entries = undefined[string, Pat]("entries")
    entryTerm = undefined[string, Pat]("entry")
    marking = (ch('!').map(_ => marked) / ch('~').map(_ => unmarked)).optional(anyMark)
    ends = notAhead(chars(symbolCharacters, "symbol character"))
    numberStart = digit().skip / (ch('-') & digit()).skip
    hex = chars(HexDigits, "hex digit")

  proc unescaped(c: char): char =
    case c
    of 'n': '\n'
    of 't': '\t'
    of 'r': '\r'
    else: c

  proc globbed(quote: char, kinds: set[Kind]): TextParser[Pat] =
    let
      escape = (ch('\\') & anyChar()).map((parts: (char, char)) => (false, parts[1].unescaped))
      wildcard = ch('*').map(_ => (true, '*'))
      plain = noneOf(quote & "\\*", "character").map((c: char) => (false, c))
    delimited(ch(quote), ch(quote), (escape / wildcard / plain).star)
      .where(
        (pieces: seq[(bool, char)]) =>
          pieces.len < 3 or pieces[1 ..^ 2].allIt(not it[0]),
        "a * only at either end")
      .map(proc(pieces: seq[(bool, char)]): Pat =
        let
          leading = pieces.len > 0 and pieces[0][0]
          trailing = pieces.len > ord(leading) and pieces[^1][0]
          payload = pieces[ord(leading) ..< pieces.len - ord(trailing)].mapIt(it[1]).join
        if leading and trailing: one(kinds).containing(payload)
        elif leading: one(kinds).endingWith(payload)
        elif trailing: one(kinds).startingWith(payload)
        else: one(kinds).exactly(payload))

  proc repeated(parts: (Pat, seq[char])): Pat =
    result = parts[0]
    for op in parts[1]:
      result =
        case op
        of '*': result.star
        of '+': result.plus
        else: result.opt

  proc loopsTake(parts: (Pat, seq[char])): bool =
    var empty = parts[0].takesNothing
    for op in parts[1]:
      if op in {'*', '+'} and empty:
        return false
      empty = empty or op in {'*', '?'}
    true

  let
    anything = ch('.').map(_ => one())
    anyNumber = ch('#').map(_ => one({bNum}))
    anyBytes = str("0x*").map(_ => one({bBytes}))
    exactBytes = sequence((str("0x"), hex.star.flatten("hex digits"), ends))
      .where((parts: (string, string, Nothing)) => parts[1].len mod 2 == 0, "an even count of hex digits")
      .map((parts: (string, string, Nothing)) => one({bBytes}).exactly(parts[1].parseHexStr))
    exactNumber = (sequence((ch('-').optional, digit().plus)).flatten("a number") & ends)
      .where((parts: (string, Nothing)) => parts[0].isValidInt, "a number")
      .map((parts: (string, Nothing)) => one({bNum}).exactly(parts[0]))
    exactNil = (str("nil") & ends).map(_ => one({bNil}))
    bareSymbol = sequence((notAhead(numberStart), chars(symbolCharacters, "symbol character").plus.flatten("a symbol")))
      .map((parts: (Nothing, string)) => one({bSym}).exactly(parts[1]))
    atom = sequence((
      choice(anything, anyNumber, anyBytes, exactBytes, exactNumber, exactNil,
        globbed('"', {bText}), globbed('\'', {bSym}), bareSymbol),
      marking,
    )).map((parts: (Pat, Option[bool])) => parts[0].withMark(parts[1]))

  proc framed(open: string, members: TextParser[Pat], close: char, kinds: set[Kind]): TextParser[Pat] =
    sequence((marking, str(open), members, ch(close).trim(ws)))
      .map((parts: (Option[bool], string, Pat, char)) => parts[2].frame(kinds, parts[0]))

  let
    postfixes = chars("*+?".filterIt(it != delimiter).join, "*, + or ?").trim(ws).star
    group = delimited(ch('<'), ch('>').trim(ws), whole)
    entry = sequence((term, ch(':').trim(ws), term))
      .map((parts: (Pat, char, Pat)) => cat(parts[0], parts[2]))
    entryGroup = delimited(ch('<').trim(ws), ch('>').trim(ws), entries)
    entryPostfixed = sequence((entry / entryGroup, postfixes))
      .where(loopsTake, "a loop whose body takes a member").map(repeated)
    entryCaptured = (ch('$').trim(ws) & entryTerm).map((parts: (char, Pat)) => parts[1].capture)
    primary = choice(
      atom,
      framed("[", whole, ']', {bList}),
      framed("(", whole, ')', {bRec}),
      framed("{", ch(':').trim(ws).map(_ => cat()), '}', {bDict}),
      framed("{", entries, '}', {bDict}),
      framed("{", whole, '}', {bSet}),
      group,
    ).trim(ws)
    postfixed = sequence((primary, postfixes))
      .where(loopsTake, "a loop whose body takes a member").map(repeated)
    captured = (ch('$').trim(ws) & term).map((parts: (char, Pat)) => parts[1].capture)
  term.define(captured / postfixed)
  whole.define(term.star.map((terms: seq[Pat]) => cat(terms)).plusSeparated(ch('|').trim(ws))
    .map((alternatives: Separated[Pat, char]) => alt(alternatives.elements)))
  entryTerm.define(entryPostfixed / entryCaptured)
  entries.define(entryTerm.plus.map((terms: seq[Pat]) => cat(terms)).plusSeparated(ch('|').trim(ws))
    .map((alternatives: Separated[Pat, char]) => alt(alternatives.elements)))
  whole

proc foldOut(parts: (Option[Address], seq[char])): Address =
  result = parts[0].get(Address(kind: adDot))
  for _ in parts[1]:
    result = Address(kind: adOut, inner: result)

proc foldRelative(parts: (Option[Address], seq[(char, Option[Address])])): Address =
  result = parts[0].get(Address(kind: adDot))
  for (op, right) in parts[1]:
    let after = right.get(Address(kind: adMember, n: 1))
    result =
      if op == '+': Address(kind: adAfter, left: result, right: after)
      else: Address(kind: adBefore, left: result, right: after)

proc foldInto(parts: (Option[Address], seq[(char, Option[Address])])): Address =
  result = parts[0].get(Address(kind: adDot))
  for (_, right) in parts[1]:
    result = Address(kind: adInto, left: result,
      right: right.get(Address(kind: adSpan, left: Address(kind: adStart), right: Address(kind: adEnd))))

proc foldSpan(parts: (Option[Address], seq[(char, Option[Address])])): Address =
  if parts[1].len == 0:
    return parts[0].get
  result = parts[0].get(Address(kind: adStart))
  for (op, right) in parts[1]:
    let ending = right.get(Address(kind: adEnd))
    result =
      if op == ',': Address(kind: adSpan, left: result, right: ending)
      else: Address(kind: adThen, left: result, right: ending)

proc present[T](parts: (Option[Address], seq[T])): bool =
  parts[0].isSome or parts[1].len > 0

proc addressGrammar(): TextParser[Address] =
  let
    ws = chars(" \t", "space")
    slot = digit().repeat(1, 9).flatten("a slot").map(parseInt).optional(0)

  proc searching(delimiter: char, backward: bool): TextParser[Address] =
    sequence((ch(delimiter), patternGrammar(delimiter), ch(delimiter), slot))
      .map((parts: (char, Pat, char, int)) =>
        Address(kind: adSearch, prog: parts[1].compileFor(parts[3]), slot: parts[3], backward: backward))

  let
    simple = choice(
      ch('.').map(_ => Address(kind: adDot)),
      ch('$').map(_ => Address(kind: adEnd)),
      digit().repeat(1, 9).flatten("a member").map((n: string) => Address(kind: adMember, n: n.parseInt)),
      searching('/', backward = false),
      searching('?', backward = true),
    ).trim(ws)
    outed = sequence((simple.optional, ch('<').trim(ws).star))
      .where(present[char], "an address").map(foldOut)
    relative = sequence((outed.optional, sequence((chars("+-", "+ or -").trim(ws), outed.optional)).star))
      .where(present[(char, Option[Address])], "an address").map(foldRelative)
    into = sequence((relative.optional, sequence((ch('>').trim(ws), relative.optional)).star))
      .where(present[(char, Option[Address])], "an address").map(foldInto)
  sequence((into.optional, sequence((chars(",;", ", or ;").trim(ws), into.optional)).star))
    .where(present[(char, Option[Address])], "an address").map(foldSpan)

func endsLast(chained: seq[Command]): bool =
  chained.len < 2 or chained[0 ..^ 2].allIt(it.steps.len == 0 or it.steps[^1].kind notin terminal)

func joined(chained: seq[Command]): Command =
  Command(steps: chained.mapIt(it.steps).concat)

proc commandGrammar(): TextParser[Command] =
  let
    ws = chars(" \t", "space")
    command = undefined[string, Command]("command")
    branch = undefined[string, Command]("branch")
    slot = digit().repeat(1, 9).flatten("a slot").map(parseInt).optional(0)
    pattern = sequence((ch('/').trim(ws), patternGrammar('/'), ch('/')))
      .map((parts: (char, Pat, char)) => parts[1])
    nested = undefined[string, Nothing]("a frame")
    listed = basslineParser(ByType[Val]())

  proc quoted(quote: char): TextParser[Nothing] =
    sequence((ch(quote), ((ch('\\') & anyChar()).skip / noneOf(quote & "\\", "character").skip).star,
      ch(quote))).skip

  let
    inside = choice(quoted('"'), quoted('\''), nested, noneOf("[](){}\"'", "a member").skip).star
  proc bracket(open, close: char): TextParser[Nothing] =
    sequence((ch(open), inside, ch(close))).skip
  nested.define(choice(bracket('[', ']'), bracket('(', ')'), bracket('{', '}')))

  let
    replacement = sequence((ws.star, bracket('[', ']').flatten("a list of the members to put")))
      .where((parts: (seq[char], string)) => (var read = listed.parse(parts[1]); read.isSuccess),
        "a list of values")
      .map(proc(parts: (seq[char], string)): seq[Val] =
        var read = listed.parse(parts[1])
        toSeq(read.take.children))
    separator = sequence((ws.star, chars("\n\r", "newline").plus, chars(" \t\n\r", "whitespace").star)).skip

  proc word(spelling: string, short = '\0'): TextParser[Nothing] =
    let long = (str(spelling) & notAhead(letter())).skip("'" & spelling & "'")
    if short == '\0': long.trim(ws)
    else: (long / (ch(short) & notAhead(letter())).skip("'" & short & "'")).trim(ws)

  let
    eachStep = sequence((word("each", 'x'), pattern, slot))
      .map((parts: (Nothing, Pat, int)) => parts[1].each(parts[2]))
    whereStep = sequence((word("where", 'g'), pattern, slot))
      .map((parts: (Nothing, Pat, int)) => parts[1].where(parts[2]))
    gapsStep = (word("gaps", 'y') & pattern).map((parts: (Nothing, Pat)) => parts[1].gaps)
    unlessStep = (word("unless", 'v') & pattern).map((parts: (Nothing, Pat)) => parts[1].unless)
    downStep = word("down").map(_ => down())
    walkStep = word("walk").map(_ => walk())
    addressStep = addressGrammar().trim(ws).map((a: Address) => at(a))
    printStep = word("print", 'p').map(_ => Command().print)
    changeStep = (word("change", 'c') & replacement).map((parts: (Nothing, seq[Val])) => Command().change(parts[1]))
    insertStep = (word("insert", 'i') & replacement).map((parts: (Nothing, seq[Val])) => Command().insert(parts[1]))
    appendStep = (word("append", 'a') & replacement).map((parts: (Nothing, seq[Val])) => Command().append(parts[1]))
    deleteStep = word("delete", 'd').map(_ => Command().delete)
    substituteStep = sequence((word("substitute", 's'), pattern, replacement, ch('g').optional)).trim(ws)
      .map((parts: (Nothing, Pat, seq[Val], Option[char])) =>
        Command().substitute(parts[1], parts[2], everyFit = parts[3].isSome))
    moveStep = (word("move", 'm') & addressGrammar().trim(ws))
      .map((parts: (Nothing, Address)) => Command().move(parts[1]))
    copyStep = (word("copy", 't') & addressGrammar().trim(ws))
      .map((parts: (Nothing, Address)) => Command().copy(parts[1]))
    steps = choice(eachStep, whereStep, gapsStep, unlessStep, downStep, walkStep, printStep,
      changeStep, insertStep, appendStep, deleteStep, substituteStep, moveStep, copyStep,
      addressStep, branch)
    filled = steps.plus.where(endsLast, "nothing after an edit or a print").map(joined)
    branchStep = sequence((
      ch('{').trim(ws), chars(" \t\n\r", "whitespace").star, filled.starSeparated(separator),
      chars(" \t\n\r", "whitespace").star, ch('}').trim(ws),
    )).map((parts: (char, seq[char], Separated[Command, Nothing], seq[char], char)) =>
      Command().branch(parts[2].elements))
  branch.define(branchStep)
  command.define(steps.star.where(endsLast, "nothing after an edit or a print").map(joined))
  command

proc read[R](grammar: TextParser[R], text: string): R =
  var read = grammar.trim(chars(" \t\n\r", "whitespace")).complete.resolve.parse(text)
  guard read.isSuccess, read.message
  read.take

# read in procs that aren't generic, so parse finds petit_parser's text input,
# which reports where reading stopped as line:column
proc readPattern(text: string): Pat =
  patternGrammar().read(text)

proc readCommand(text: string): Command =
  commandGrammar().read(text)

proc readAddress(text: string): Address =
  addressGrammar().read(text)

proc parse*(T: typedesc[Pat], text: string): Pat =
  readPattern(text)

proc parse*(T: typedesc[Command], text: string): Command =
  readCommand(text)

proc parse*(T: typedesc[Address], text: string): Address =
  readAddress(text)