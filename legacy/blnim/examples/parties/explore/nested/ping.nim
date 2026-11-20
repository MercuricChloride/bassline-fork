## Two programs at the party it is pointed at. One hears (ping) and
## answers each by saying (pong I) into what whoever said it goes by.
## The other says (ping) I, one at a time, and keeps how long each took
## to be answered. `ping HOST PORT` prints the median in ms.

import std/[algorithm, os, strutils, times]
import bl/core
import bl/parties/parties

type Pair* = ref object
  pinger, ponger: Attendee

proc answering(p: Pair) {.async.} =
  p.ponger.each msg:
    if msg.topic == bl"(ping)":
      let i = msg.value
      discard p.ponger.say(msg.by, bl"(pong $i)")

proc pair*(at: IpAddress, port: Port): Future[Pair] {.async.} =
  let p = Pair(pinger: attend(at, port), ponger: attend(at, port))
  p.ponger.sub bl"(ping)"
  await p.pinger.ready
  await p.ponger.ready
  asyncCheck p.answering
  await sleepAsync(200)  # for the sub to land
  return p

proc rounds*(p: Pair, n: int): Future[seq[float]] {.async.} =
  ## how long each of `n` pings took to be answered, in ms
  for i in 1 .. n:
    let t0 = epochTime()
    p.pinger.say bl"(ping)", bl"$i"
    while true:
      let m = await p.pinger.next
      if m.isNone: return
      if m.get.value == bl"(pong $i)": break
    result.add (epochTime() - t0) * 1000

proc close*(p: Pair) =
  p.pinger.close
  p.ponger.close

proc median*(xs: seq[float]): float = xs.sorted[xs.len div 2]

when isMainModule:
  if paramCount() < 2: quit "ping HOST PORT"
  let p = waitFor pair(parseIpAddress(paramStr(1)), Port(paramStr(2).parseInt))
  echo (waitFor p.rounds(100)).median.formatFloat(ffDecimal, 2), " ms"
