import std/[deques, tables, hashes, algorithm, strutils]
import ../core
import ./print

type
  Pid* = distinct int32
  Emit* = proc(label: Value, v: sink Value)
  Step* = proc(state: var Value, msg: sink Value, emit: Emit)

  Behavior* = object
    read*: Step ## hears inert values; nil discards them
    exec*: Step ## hears marked values; nil discards them

  DestKind* = enum
    dPid
    dAlias

  Dest* = object
    ## a route destination, readable through the window
    case kind*: DestKind
    of dPid:
      pid*: Pid
    of dAlias:
      name*: Value

  Process* = object
    pid*: Pid
    live*: bool
    behavior*: Value ## key into the runtime's behavior table
    state*: Value
    mailbox*: Deque[Value]
    queued*: bool    ## in the runq
    reductions*: int
    dropped*: int    ## messages a missing lane discarded

  Runtime* = ref object
    behaviors: Table[Value, Behavior]
    procs: seq[Process]
    aliases: Table[Value, Pid]
    routes: Table[(Pid, Value), seq[Dest]]
    runq: Deque[Pid]
    stepping: bool
    lastReduced*: Pid ## bookkeeping: who reduced last; does not travel

func `==`*(a, b: Pid): bool {.borrow.}
func hash*(a: Pid): Hash {.borrow.}
func `$`*(a: Pid): string {.borrow.}

const
  NoPid = Pid(-1)
  ErrorsName* = record(sym"runtime", sym"errors")
    ## hold this name to hear (raised <behavior> <msg> <text>)
  UnheardName* = record(sym"runtime", sym"unheard")
    ## hold this name to hear (unheard <behavior> <msg>) and
    ## (gone <behavior> <msg>)

template stepIt*(body: untyped): Step =
  ## an anonymous Step with the state, the message, and the emitter
  ## injected as `state`, `it`, and `emit`
  (
    proc(
        state {.inject.}: var Value, it {.inject.}: sink Value,
            emit {.inject.}: Emit
    ) =
    body
  )

proc initRuntime*(): Runtime =
  Runtime(lastReduced: NoPid)

# ================ RESHAPING ================
# Everything here asserts it runs between steps, never during one.

proc reshapes(rt: Runtime) =
  doAssert not rt.stepping, "the runtime is reshaped between steps, not during"

proc install*(rt: Runtime, key: Value, b: Behavior) =
  reshapes rt
  rt.behaviors[key] = b

proc spawn*(rt: Runtime, behavior: Value, init: Value = nilValue()): Pid =
  reshapes rt
  if behavior notin rt.behaviors:
    raise newException(ValueError, "spawn: a behavior you don't hold: " & $behavior)
  result = Pid(rt.procs.len)
  rt.procs.add Process(
    pid: result, live: true, behavior: behavior, state: init,
    mailbox: initDeque[Value]()
  )

proc kill*(rt: Runtime, pid: Pid) =
  ## a local decision: the mailbox drops, senders learn nothing
  reshapes rt
  rt.procs[int(pid)].live = false
  rt.procs[int(pid)].mailbox.clear()

proc alias*(rt: Runtime, name: Value, pid: Pid) =
  ## set or retarget: the next emission through this name follows it
  reshapes rt
  rt.aliases[name] = pid

proc unalias*(rt: Runtime, name: Value) =
  reshapes rt
  rt.aliases.del name

proc wire*(rt: Runtime, src: Pid, label: Value, dst: Pid) =
  ## early-bound: this destination is fixed
  reshapes rt
  rt.routes.mgetOrPut((src, label), @[]).add Dest(kind: dPid, pid: dst)

proc wire*(rt: Runtime, src: Pid, label: Value, dst: Value) =
  ## late-bound: the alias re-resolves at every emission
  reshapes rt
  rt.routes.mgetOrPut((src, label), @[]).add Dest(kind: dAlias, name: dst)

proc dropDest(rt: Runtime, src: Pid, label: Value, matches: proc(d: Dest): bool) =
  let key = (src, label)
  if key notin rt.routes:
    return # unwiring what was never wired is silence, like unalias
  var ds = rt.routes[key]
  for i in 0 ..< ds.len:
    if matches(ds[i]):
      ds.delete(i)
      break
  if ds.len == 0:
    rt.routes.del key
  else:
    rt.routes[key] = ds

proc unwire*(rt: Runtime, src: Pid, label: Value, dst: Pid) =
  ## remove one early-bound destination
  reshapes rt
  rt.dropDest(src, label, proc(d: Dest): bool =
    d.kind == dPid and d.pid == dst)

proc unwire*(rt: Runtime, src: Pid, label: Value, dst: Value) =
  ## remove one late-bound destination
  reshapes rt
  rt.dropDest(src, label, proc(d: Dest): bool =
    d.kind == dAlias and d.name == dst)

proc unwire*(rt: Runtime, src: Pid, label: Value) =
  ## remove the whole label
  reshapes rt
  rt.routes.del (src, label)

# ================ DELIVERY ================

proc enqueue(rt: Runtime, pid: Pid, v: sink Value) =
  ## raw delivery: the dead and the unknown hear nothing
  let i = int(pid)
  if i < 0 or i >= rt.procs.len or not rt.procs[i].live:
    return
  rt.procs[i].mailbox.addLast v
  if not rt.procs[i].queued:
    rt.procs[i].queued = true
    rt.runq.addLast pid

proc report(rt: Runtime, name: Value, v: sink Value, about: Pid) =
  ## local misfortune, spoken to whoever holds the name. Never about
  ## its own listener and never meta: an unheld name or a dead
  ## listener is silence
  let t = rt.aliases.getOrDefault(name, NoPid)
  if t == NoPid or t == about:
    return
  rt.enqueue(t, v)

proc deliver(rt: Runtime, pid: Pid, v: sink Value) =
  let i = int(pid)
  if i < 0 or i >= rt.procs.len:
    return # nothing is known about the unknown, so nothing is said
  if not rt.procs[i].live:
    # the runtime knows its own dead and may say so — locally. This
    # claims nothing about anyone beyond the runtime
    rt.report(UnheardName, record(sym"gone", rt.procs[i].behavior, v), pid)
    return
  rt.enqueue(pid, v)

proc target(rt: Runtime, d: Dest): Pid =
  case d.kind
  of dPid:
    d.pid
  of dAlias:
    rt.aliases.getOrDefault(d.name, NoPid)

proc emitFrom(rt: Runtime, src: Pid, label: Value, v: Value) =
  let key = (src, label)
  if key notin rt.routes:
    return # speaking where nothing is wired is silence
  for d in rt.routes[key]:
    let t = rt.target(d)
    if t != NoPid:
      let dup = v
      rt.deliver(t, dup)

proc post*(rt: Runtime, to: Pid, v: sink Value) =
  ## the driver's door: put a value in a mailbox
  rt.deliver(to, v)

proc post*(rt: Runtime, to: Value, v: sink Value) =
  ## by alias; a name nobody holds hears nothing
  let t = rt.aliases.getOrDefault(to, NoPid)
  if t != NoPid:
    rt.deliver(t, v)

# ================ STEPPING ================

proc errorTarget(rt: Runtime, pid: Pid): Pid =
  ## who hears (raised …) for this process: nobody when the name is
  ## unheld, dead, or the process itself — then the error propagates
  let t = rt.aliases.getOrDefault(ErrorsName, NoPid)
  if t == NoPid or t == pid:
    return NoPid
  let i = int(t)
  if i < 0 or i >= rt.procs.len or not rt.procs[i].live:
    return NoPid
  t

proc step*(rt: Runtime): bool =
  ## one reduction: the next runnable process hears one message.
  ## False when nothing is runnable. A raising lane becomes a
  ## (raised …) message when someone holds the errors name; held by
  ## nobody, it propagates and the consumed message goes with it.
  ## Either way the process keeps its remaining mail. Defects are
  ## never messages; only catchable errors are
  doAssert not rt.stepping, "step during step: drivers don't nest"
  while rt.runq.len > 0:
    let pid = rt.runq.popFirst
    let i = int(pid)
    rt.procs[i].queued = false
    if not rt.procs[i].live or rt.procs[i].mailbox.len == 0:
      continue
    let msg = rt.procs[i].mailbox.popFirst
    let behavior = rt.procs[i].behavior
    let lane =
      if msg.marked:
        rt.behaviors[behavior].exec
      else:
        rt.behaviors[behavior].read
    inc rt.procs[i].reductions
    rt.lastReduced = pid
    if lane == nil:
      inc rt.procs[i].dropped
      rt.report(UnheardName, record(sym"unheard", behavior, msg), pid)
    else:
      let errAt = rt.errorTarget(pid)
      let kept = if errAt == NoPid: nilValue() else: msg
      rt.stepping = true
      let emit: Emit = proc(label: Value, ev: sink Value) =
        rt.emitFrom(pid, label, ev)
      try:
        lane(rt.procs[i].state, msg, emit)
      except CatchableError as e:
        if errAt == NoPid:
          raise
        rt.enqueue(errAt, record(sym"raised", behavior, kept, text(e.msg)))
      finally:
        rt.stepping = false
        if rt.procs[i].mailbox.len > 0 and not rt.procs[i].queued:
          rt.procs[i].queued = true
          rt.runq.addLast pid
    if rt.procs[i].mailbox.len > 0 and not rt.procs[i].queued:
      rt.procs[i].queued = true
      rt.runq.addLast pid
    return true
  false

proc pump*(rt: Runtime, quantum: int): int =
  ## at most `quantum` reductions; how many ran
  while result < quantum and rt.step():
    inc result

proc drive*(rt: Runtime) =
  ## the greedy driver: to quiescence
  while rt.step():
    discard

func done*(rt: Runtime): bool =
  ## the runq is drained. Entries for the dead drain lazily, so done
  ## may briefly say false when nothing will actually run
  rt.runq.len == 0

# ================ LOOKING IN ================
# Transparency is the point: what a scheduler or a screen would read.
# The window is lent: every field is public to look at, and nothing
# outside the runtime can mutate through it. The loan is momentary —
# read it and let go, never in the same expression as a reshaping
# call, and taking its address is out of contract. `let p = rt[pid]`
# usually binds a deep copy, but the optimizer may borrow: keep its
# last use before any reshape.

func len*(rt: Runtime): int =
  rt.procs.len

func `[]`*(rt: Runtime, pid: Pid): lent Process =
  rt.procs[int(pid)]

iterator eachRoute*(rt: Runtime): (Pid, Value, seq[Dest]) =
  ## the wiring, for a screen: (from, label, destinations). The
  ## tables are read where they lie — collect first if you mean to
  ## reshape; never reshape mid-walk
  for key, dests in rt.routes:
    yield (key[0], key[1], dests)

iterator eachAlias*(rt: Runtime): (Value, Pid) =
  for name, pid in rt.aliases:
    yield (name, pid)

iterator eachBehavior*(rt: Runtime): Value =
  ## the palette: every behavior key held
  for k in rt.behaviors.keys:
    yield k

# ================ THE RUNTIME AS A VALUE ================
# (runtime [procs] {aliases} [routes]) — a proc is
# (proc <behavior> <state> [mail…]) or (gone); a destination is
# (pid <n>) or (alias <name>). Everything but the behavior table.

proc snapshot*(rt: Runtime): Value =
  doAssert not rt.stepping, "a snapshot is a between-steps read"
  var ps: seq[Value]
  for p in rt.procs:
    if not p.live:
      ps.add record(sym"gone")
    else:
      var mail: seq[Value]
      for m in p.mailbox:
        mail.add m
      ps.add record(sym"proc", p.behavior, p.state, list(mail))
  var als: seq[(Value, Value)]
  for name, pid in rt.aliases:
    als.add (name, num($int(pid)))
  var rts: seq[Value]
  for key, dests in rt.routes:
    let (src, label) = key
    var ds: seq[Value]
    for d in dests:
      case d.kind
      of dPid:
        ds.add record(sym"pid", num($int(d.pid)))
      of dAlias:
        ds.add record(sym"alias", d.name)
    rts.add record(sym"route", num($int(src)), label, list(ds))
  rts.sort(cmp)
  record(sym"runtime", list(ps), dict(als), list(rts))

proc restore*(rt: Runtime, doc: Value) =
  ## fill a fresh runtime, behaviors already installed, from a
  ## snapshot. All-or-nothing: a refusal commits nothing, and the
  ## dialect accepted is exactly the one snapshot speaks — inert
  ## structure, pids as positions in this document, one route per
  ## (from, label). Document problems refuse with ValueError; driver
  ## misuse is a Defect
  reshapes rt
  doAssert rt.procs.len == 0, "restore fills a fresh runtime"

  proc bad(msg: string) {.noreturn.} =
    raise newException(ValueError, "restore: " & msg)

  if doc.kind != bRecord or doc.marked or doc.head != sym"runtime" or
      doc.contents.len != 4:
    bad "a snapshot is an inert (runtime [procs] {aliases} [routes])"
  let (ps, als, rts) = (doc.contents[1], doc.contents[2], doc.contents[3])
  if ps.kind != bList or als.kind != bDict or rts.kind != bList:
    bad "a snapshot is an inert (runtime [procs] {aliases} [routes])"
  let count = ps.contents.len

  proc asPid(v: Value): Pid =
    if v.kind != bNum or v.marked:
      bad "a pid is an inert number"
    var n: int
    try:
      n = parseInt(string(v.num))
    except ValueError:
      bad "a pid is a position in this document: " & $v
    if n < 0 or n >= count:
      bad "a pid is a position in this document: " & $v
    Pid(int32(n))

  var procs: seq[Process]
  for p in ps.contents:
    if p.kind != bRecord or p.marked:
      bad "a proc is an inert record"
    if p.head == sym"gone":
      if p.contents.len != 1:
        bad "gone is (gone)"
      procs.add Process(pid: Pid(procs.len), live: false)
    elif p.head == sym"proc" and p.contents.len == 4 and p.contents[3].kind == bList:
      let behavior = p.contents[1]
      if behavior notin rt.behaviors:
        bad "a behavior you don't hold: " & $behavior
      var mb = initDeque[Value]()
      for m in p.contents[3].contents:
        mb.addLast m
      procs.add Process(
        pid: Pid(procs.len), live: true, behavior: behavior,
        state: p.contents[2], mailbox: mb
      )
    else:
      bad "a proc is (proc <behavior> <state> [mail…]) or (gone)"

  var aliases: Table[Value, Pid]
  for k, pd in als.pairs:
    aliases[k] = asPid(pd)

  var routes: Table[(Pid, Value), seq[Dest]]
  for r in rts.contents:
    if r.kind != bRecord or r.marked or r.head != sym"route" or
        r.contents.len != 4 or r.contents[3].kind != bList:
      bad "a route is an inert (route <from> <label> [dests…])"
    let key = (asPid(r.contents[1]), r.contents[2])
    if key in routes:
      bad "two routes for one (from, label): " & $r.contents[1] & " " & $r.contents[2]
    var ds: seq[Dest]
    for d in r.contents[3].contents:
      if d.kind == bRecord and not d.marked and d.head == sym"pid" and
          d.contents.len == 2:
        ds.add Dest(kind: dPid, pid: asPid(d.contents[1]))
      elif d.kind == bRecord and not d.marked and d.head == sym"alias" and
          d.contents.len == 2:
        ds.add Dest(kind: dAlias, name: d.contents[1])
      else:
        bad "a destination is an inert (pid <n>) or (alias <name>)"
    routes[key] = ds

  # nothing above touched the runtime; the commit is whole
  rt.procs = procs
  rt.aliases = aliases
  rt.routes = routes
  # runnable-ness never travels: a restore derives it from the
  # mailboxes and begins the round in pid order — turn order and the
  # counts are run, not state
  for i in 0 ..< rt.procs.len:
    if rt.procs[i].live and rt.procs[i].mailbox.len > 0:
      rt.procs[i].queued = true
      rt.runq.addLast Pid(i)
