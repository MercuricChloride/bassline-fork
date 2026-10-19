## A party that is a participant of another. Each connection to it is a
## connection of its own to the party inside, which names it and orders
## everything it hears. The fence passes on what is said to it only into
## the topics it admits, into its own name, and into the names of those
## it has heard from, and owns and hears only topics it admits. Anything
## else it says inside as (fenced X), outside the dialect, so the party
## inside says it back as (invalid (fenced X)) in its own order. It goes
## by (fenced TOPICS P), P what the party inside goes by. Either side
## ending ends both.
import std/[os, strutils]
import bl/core
import ./kernel

type Pass = ref object
  outer, inner: AsyncSocket
  topics: Value
  heard: seq[Value]  ## its own name, then each it has heard from

proc ends(p: Pass) =
  p.outer.close
  p.inner.close

proc answerable(p: Pass, t: Value): bool =
  t in p.topics.els or t in p.heard

proc admits(p: Pass, said: Value): bool =
  matchValue said:
  of "(sub $t)": t in p.topics.els
  of "(say $t $_)": p.answerable t
  of "(own $ts)":
    if ts.kind != bSet: return true
    for t in ts.els:
      if t notin p.topics.els: return false
    true
  else: true

proc down(p: Pass) {.async.} =
  ## what the party inside tells, out
  let r = reader(p.inner)
  while true:
    let v = await r.read
    if v.isNone: break
    var told = v.get
    let topics = p.topics
    matchValue told:
    of "(name $n $s $party)":
      p.heard.add s
      told = bl"(name $n $s (fenced $topics $party))"
    of "(said $_ $_ $_ $by)":
      if by.kind != bNil and by notin p.heard: p.heard.add by
    else: discard
    try: await p.outer.send(told.ce.toString, flags = {})
    except CatchableError: break
  p.ends

proc up(p: Pass) {.async.} =
  ## what is said to the fence, in
  let r = reader(p.outer)
  while true:
    let v = await r.read
    if v.isNone: break
    let said = v.get
    let passed = if p.admits(said): said else: bl"(fenced $said)"
    try: await p.inner.send(passed.ce.toString, flags = {})
    except CatchableError: break
  p.ends

proc fence*(inner: (IpAddress, Port), topics: Value, at = parseIpAddress("::1"),
            port = Port(0)): AsyncSocket =
  ## a fence at `at` and `port` in front of the party at `inner`
  let l = newAsyncSocket(at.domainOf, buffered = false)
  l.setSockOpt(OptReuseAddr, true)
  l.bindAddr(port, $at)
  l.listen
  proc accepting() {.async.} =
    while not l.isClosed:
      var outer: AsyncSocket
      try: outer = await l.accept
      except CatchableError:
        if l.isClosed: break
        await sleepAsync(100)
        continue
      let p = Pass(outer: outer, topics: topics,
                   inner: newAsyncSocket(inner[0].domainOf, buffered = false))
      try: await p.inner.connect($inner[0], inner[1])
      except CatchableError:
        p.ends
        continue
      asyncCheck p.down
      asyncCheck p.up
  asyncCheck accepting()
  l

when isMainModule:
  if paramCount() != 2: quit "fence INNER-PORT TOPICS"
  let l = fence((parseIpAddress("::1"), Port(parseInt(paramStr(1)))), readValue(paramStr(2)))
  echo "[::1]:", l.getLocalAddr[1].int
  stdout.flushFile
  runForever()
