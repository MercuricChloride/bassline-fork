## A party that keeps everything it says, in its order, in a log, a bare
## concatenation of CE: (order P) first, then each (name N S P) and
## (said N T V S) once, kept before anyone is told it. Served again on
## the same log it goes by the same P and its order goes on from there.
## One it can't keep, it doesn't say: it stops.
import std/[os, sysrand]
import bl/core
import bl/lib/bvarfile
import ./kernel

type Recorder* = ref object of Party
  log: string

method record(p: Recorder, v: Value) =
  if not appendValue(p.log, v): quit "can't keep " & $v & " in " & p.log

proc recorder*(log: string): Recorder =
  result = Recorder(log: log)
  let kept = if fileExists(log): valuesIn(log) else: @[]
  if kept.len == 0:
    let order = bytes(urandom 16)
    result.name = bl"(recorder $order)"
    let name = result.name
    result.record bl"(order $name)"
    return
  matchValue kept[0]:
  of "(order $p)": result.name = p
  else: quit log & " isn't a recorder's log"
  matchValue kept[^1]:
  of "(said $n &_)": result.said = n.num.toInt
  of "(name $n &_)": result.said = n.num.toInt
  else: discard

when isMainModule:
  if paramCount() < 1: quit "recorder LOG [show]"
  if paramCount() == 2:
    for v in valuesIn(paramStr(1), mend = false): echo v
    quit 0
  recorder(paramStr(1)).serve.announce
  runForever()
