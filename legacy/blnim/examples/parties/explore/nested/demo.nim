## Parties inside topics, in one process, every party on [::1] at a
## port of its own:
##
## 1. The scene of basics.nim, unchanged, at a party, and then at the
##    party hosted inside (room) at another, through a bridge.
## 2. Parties three deep, (room) at the party, (den) inside it, (nook)
##    inside that: how long a ping takes at each depth, and how many
##    things the party outside says for each.
## 3. Handover: the owner of (room) goes, a standby owner takes it after
##    its backoff, and later the standby goes and a fresh owner takes it
##    at once, while ann and bob tick inside.

import std/[strutils, times]
import bl/core
import ./[nest, scene, ping, ticks]

let lo = parseIpAddress("::1")

proc mark(q1, q2: Attendee): Future[int] {.async.} =
  ## where the party says something now, in its order
  q1.say q2.name, bl"(mark)"
  while true:
    let m = await q2.next
    if m.get.value == bl"(mark)": return m.get.n

proc same() {.async.} =
  echo "1. the scene, at a party and inside (room) at another"
  let p0 = serve(lo, Port(0))
  let direct = await scene(lo, p0.port)
  let p1 = serve(lo, Port(0))
  discard host(lo, p1.port, bl"(room)")
  let b = bridge(lo, p1.port, bl"(room)")
  let inside = await scene(lo, b)
  for l in direct: echo "   ", l
  if inside == direct: echo "   inside (room) the scene writes the same ", inside.len, " lines"
  else:
    echo "   inside (room) it writes otherwise:"
    for l in inside: echo "   ", l

proc deep() {.async.} =
  echo "\n2. a ping at each depth: median ms of 100, and things the party outside says for each"
  let p = serve(lo, Port(0))
  var ports = @[p.port]
  for t in [bl"(room)", bl"(den)", bl"(nook)"]:
    discard host(lo, ports[^1], t)
    ports.add bridge(lo, ports[^1], t)
  let (q1, q2) = (attend(lo, p.port), attend(lo, p.port))
  await q1.ready
  await q2.ready
  for d, port in ports:
    let pp = await pair(lo, port)
    let n0 = await mark(q1, q2)
    let ms = await pp.rounds(100)
    let n1 = await mark(q1, q2)
    echo "   depth ", d, ": ", ms.median.formatFloat(ffDecimal, 2), " ms, ",
      (n1 - n0 - 1) div 100, " says"
    pp.close
    await sleepAsync(200)

proc handover() {.async.} =
  echo "\n3. handover, as bob inside (room) writes it"
  let p = serve(lo, Port(0))
  let a = host(lo, p.port, bl"(room)")
  await sleepAsync(300)
  let b = host(lo, p.port, bl"(room)")  # a standby, refused while a owns (room)
  let bridged = bridge(lo, p.port, bl"(room)")
  let t0 = epochTime()
  proc at(): string = (epochTime() - t0).formatFloat(ffDecimal, 1)
  let bobs = ticks(lo, bridged, 14)
  var told: seq[string]
  await sleepAsync(4000)
  a.close
  told.add at() & " the owner goes"
  while b.seated == 0: await sleepAsync(10)
  told.add at() & " the standby hosts its first seat"
  await sleepAsync(9000 - int((epochTime() - t0) * 1000))
  b.close
  let c = host(lo, p.port, bl"(room)")
  told.add at() & " the standby goes, and a fresh owner starts"
  while c.seated == 0: await sleepAsync(10)
  told.add at() & " the fresh owner hosts its first seat"
  for l in await bobs: echo "   ", l
  for l in told: echo "   ", l

proc main() {.async.} =
  await same()
  await deep()
  await handover()

waitFor main()
