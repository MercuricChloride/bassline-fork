## Two programs at the party it is pointed at. ann says (tick I) into
## (news) every 100 ms. bob hears (news) and writes when he arrives,
## and in which party's order, and which ticks he heard, a run to a
## line. `ticks HOST PORT SECONDS` prints what bob wrote.

import std/[os, strutils, times]
import bl/core
import bl/parties/parties

type Run = object
  party: string
  first, last: int
  since, until: float

proc ago(t0: float): string = (epochTime() - t0).formatFloat(ffDecimal, 1)

proc short(v: Value): string = ($v)[2 .. 7]

proc bob(a: Attendee, t0: float, lines: ref seq[string]) {.async.} =
  var run: Run
  proc flush() =
    if run.last > 0:
      lines[].add run.since.formatFloat(ffDecimal, 1) & " to " &
        run.until.formatFloat(ffDecimal, 1) & " bob hears ticks " & $run.first &
        " to " & $run.last
    run = Run()
  a.each msg:
    let at = epochTime() - t0
    matchValue msg.value:
    of "(name $_)":
      flush()
      lines[].add t0.ago & " bob arrives, in the order of party " & msg.party.short
    of "(tick $tick)":
      let i = tick.num.toInt
      if run.last == 0 or i != run.last + 1 or run.party != msg.party.short:
        flush()
        run = Run(party: msg.party.short, first: i, since: at)
      run.last = i
      run.until = at
    else: discard
  flush()

proc ticks*(at: IpAddress, port: Port, seconds: float): Future[seq[string]] {.async.} =
  ## bob's lines, and how many ticks ann said, after `seconds`
  let lines = new seq[string]
  let
    t0 = epochTime()
    ann = attend(at, port)
    b = attend(at, port)
  b.sub bl"(news)"
  asyncCheck bob(b, t0, lines)
  await ann.ready
  await b.ready
  await sleepAsync(200)
  var said = 0
  while epochTime() - t0 < seconds:
    inc said
    ann.say bl"(news)", bl"(tick $said)"
    await sleepAsync(100)
  await sleepAsync(500)
  ann.close
  b.close
  await sleepAsync(50)
  lines[].add "ann said ticks 1 to " & $said
  return lines[]

when isMainModule:
  if paramCount() < 3: quit "ticks HOST PORT SECONDS"
  for l in waitFor ticks(parseIpAddress(paramStr(1)), Port(paramStr(2).parseInt),
                         paramStr(3).parseFloat):
    echo l
