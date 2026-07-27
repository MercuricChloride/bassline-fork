import ../core
import ./[grammar, print]
import std/[deques, sugar]

type
  Send* = proc(v: sink Value): void

  Job* = object
    value: Value
    handler: Send

  Sched* = ref object
    q: Deque[Job]
    busy: bool

template sendIt*(body: untyped): Send =
  ## an anonymous Send with the value injected as `it`
  (
    proc(it {.inject.}: sink Value): void =
      body
  )


proc sendVoid(v: sink Value): void = discard

func initSched*(): Sched =
  var q = initDeque[Job]()
  Sched(q: q)

func send*(value: sink Value, handler: Send = sendVoid): Job =
  Job(value: value, handler: handler)

func schedule*(sched: Sched, job: sink Job): void =
  addFirst[Job](sched.q, job)

func done*(s: Sched): bool =
  s.q.len == 0

proc execute(job: Job): void =
  job.handler(job.value)

proc step*(s: Sched): bool =
  ## Runs one job to completion. False when there was nothing to run.
  ## An error in the job propagates; the queue keeps the rest.
  doAssert not s.busy, "step during step: drivers don't nest"
  if s.done:
    return false
  s.busy = true
  defer:
    s.busy = false
  s.q.popLast.execute()
  true

proc drive*(s: Sched) =
  ## the greedy driver: to quiescence
  while s.step():
    discard

proc via*(s: Sched, k: Send): Send =
  sendIt:
    s.schedule(send(it, k))

# ================ SOME SENDS ================

proc logger*(msg: string): Send =
  sendIt:
    echo msg & $it

proc fwd*(f: proc(v: sink Value): Value, s: Send): Send =
  sendIt:
    s(f(it))

proc fanout*(v: sink Value, sends: openArray[Send]): void =
  for s in sends:
    let val = v
    s(val)

proc keep*(pred: proc(v: Value): bool, s: Send): Send =
  sendIt:
    if pred(it): s(it)

proc route*(
    gr: ref Grammar,
    table: openArray[(string, Send)],
    rest: Send = sendVoid,
    refused: Send = sendVoid,
    budget = DefaultBudget,
): Send =
  ## the actions table: rules name recognitions, Sends are what is done
  ## about them, and the table marrying the two is local machinery that
  ## never travels. Recognition is additive, so every lane whose rule
  ## admits the value speaks. When no rule answers, `rest` hears it —
  ## unless refusal is what blocked an answer, then `refused` does.
  ## Rule names resolve at wiring time.
  for (name, _) in table:
    doAssert name in gr[].ruleNames, "unknown rule: " & name
  let entries = @table
  sendIt:
    var spoke = false
    var blocked = false
    for (name, lane) in entries:
      case gr[].judge(name, it, budget)
      of vAccepted:
        spoke = true
        let v = it
        lane(v)
      of vRefused:
        blocked = true
      of vRejected:
        discard
    if not spoke:
      let v = it
      if blocked: refused(v) else: rest(v)

type Prop* = ref object
  port*: Send
  targets*: seq[Send]

proc propagator*(f: proc(v: Value, s: Send): void): Prop =
  var p = Prop(targets: @[])
  proc sendAll(v: sink Value): void =
    for t in p.targets:
      t(v)
  p.port = sendIt: f(it, sendAll)
  return p

when isMainModule:
  import std/strutils

  proc asInt(v: Value): int =
    parseInt(string(v.num))

  let s = initSched()

  # 1. a fused pipeline behind one via edge: keep evens, double them.
  #    keep/fwd run on the stack; the queue sees one job per value.
  echo "-- pipeline --"
  let pipeline = via(
    s,
    keep(
      (v: Value) => v.asInt mod 2 == 0,
      fwd(
        (v: sink Value) => num($(v.asInt * 2)),
        logger("doubled: ")
      )
    ),
  )
  for i in 1 .. 10:
    pipeline(num($i))
  drive s

  # 2. state lives in capture, not in the sched: a running sum.
  echo "-- summing --"
  proc summing(k: Send): Send =
    var total = 0
    sendIt:
      total += it.asInt
      k(num($total))

  let totals = summing(logger("total: "))
  for i in 1 .. 5:
    totals(num($i))

  # 3. a propagator fanning out: each value spoken twice to two ears.
  echo "-- fanout --"
  proc pTwice(v: Value, s: Send) =
    s(v)
    s(v)

  let baz = propagator(pTwice)
  baz.targets.add [logger("foo says: "), logger("bar says: ")]
  s.schedule send(sym"hello", baz.port)
  drive s

  # 4. recognition routes: an actions table over a shared grammar.
  #    Recognition is additive — a point is also a wide record — so
  #    both lanes speak; the unrecognized fall through to rest.
  echo "-- routing --"
  let gr = new Grammar
  gr[] =
    readGrammar"""{
    point: [!(num) !(num)]
    triple: ( !(any) !(any) !(any) )
    tag: !(sym)
  }"""
  let router = route(
    gr,
    {"point": logger("point: "), "triple": logger("triple: "), "tag": logger("tag: ")},
    rest = logger("unrecognized: "),
  )
  for v in [
    list(num"1", num"2"),
    sym"north",
    text"noise",
    record(sym"hello", sym"there", sym"world!")]:
    router(v)

  # keep over the same grammar: the recognizer is the predicate
  let onlyPoints = keep(gr.recognizer("point"), logger("kept: "))
  onlyPoints(list(num"3", num"4"))
  onlyPoints(sym"north")

  # 5. a cycle crossing a via edge: 100_000 self-sends, flat stack.
  echo "-- countdown --"
  var
    transcript: seq[Value] = @[]
    countdown: Send

  let
    landed = logger("landed: ")
    rec = (v: sink Value) => transcript.add(v)

  countdown = via(
    s,
    (v: sink Value) => (
      let n = v.asInt
      if n == 0:
        v.fanout([landed, rec])
      else:
        let next = num($(n - 1))
        next.fanout([countdown, rec])
    )
  )
  countdown(num("100000"))
  drive s
  echo "queue drained: ", s.done
  echo transcript.len
