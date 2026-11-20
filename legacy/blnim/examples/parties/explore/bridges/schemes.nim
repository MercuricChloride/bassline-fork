## Bridges carrying (kitchen) between parties in a ring or a mesh, to
## measure what each way of stopping loops costs. A guest at party 0 says
## one order, and then the same order again, and after a while each
## party's listener has heard what it heard.
##
##   schemes plain|digest|hops|gates [N] [mesh]
##
## plain carries everything heard, digest carries only what the bridge
## hasn't carried or heard before (by the digest of the value), and hops
## wraps a value in (via [P …] V), every party it has been said at, and
## never carries it to one of those. gates is the fabric: a gate at each
## party and its bridges. Each run prints one value:
##
##   (measured SCHEME (ring N) {lines: L first: [H …] again: [H …]})
##
## L the lines the bridges carried, and H how many times each party heard
## the first order, and then the second, the same value said again.

import std/[os, sequtils, strutils]
import bl/core
import bl/lib/crypto/digest
import ./fabric

type
  Scheme = enum plain, digest, hops, gates
  Hop = ref object
    ends: array[2, Attendee]
    parties: array[2, Value]
    seen: BSet
    carried: int

let
  here = parseIpAddress("::1")
  kitchen = bl"(kitchen)"

proc carrying(b: Hop, i: int, scheme: Scheme) {.async.} =
  let (src, dst) = (b.ends[i], b.ends[1 - i])
  src.each msg:
    if msg.by.kind == bNil: b.parties[i] = msg.party
    elif msg.topic == kitchen:
      case scheme
      of plain:
        discard dst.say(kitchen, msg.value)
        inc b.carried
      of digest:
        let d = digest(msg.value, Blake2bAlgo).toValue
        if d notin b.seen:
          b.seen.incl d
          discard dst.say(kitchen, msg.value)
          inc b.carried
      of hops:
        var (path, v) = (newSeq[Value](), msg.value)
        matchValue msg.value:
        of "(via [&ps] $x)": (path, v) = (ps, x)
        else: discard
        let (at, to) = (b.parties[i], b.parties[1 - i])
        if to notin path:
          discard dst.say(kitchen, bl"(via [@path $at] $v)")
          inc b.carried
      of gates: discard

type Heard = ref object
  counts: seq[int]  ## the orders each party's listener heard

proc listen(h: Heard, i: int, a: Attendee) {.async.} =
  a.each msg:
    matchValue msg.value:
    of "(via $_ (order $_))": inc h.counts[i]
    of "(order $_)": inc h.counts[i]
    else: discard

proc main(scheme: Scheme, n: int, mesh: bool) {.async.} =
  let places = (0 ..< n).mapIt((here, serve(here, Port(0)).port))
  var
    bridges: seq[Hop]
    fabric: seq[Bridge]
  if scheme == gates:
    for p in places: discard gate(p[0], p[1], @[kitchen])
  for i in 0 ..< n:
    for j in i + 1 ..< n:
      if not (mesh or j == i + 1 or (i == 0 and j == n - 1 and n > 2)): continue
      if scheme == gates:
        fabric.add bridge(places[i], places[j])
      else:
        let b = Hop(ends: [attend(places[i][0], places[i][1]), attend(places[j][0], places[j][1])],
                    seen: newBSet())
        bridges.add b
        for k in 0 .. 1:
          b.ends[k].sub kitchen
          asyncCheck b.carrying(k, scheme)
  let heard = Heard(counts: newSeq[int](n))
  for i, p in places:
    let a = attend(p[0], p[1])
    a.sub kitchen
    asyncCheck heard.listen(i, a)
  let guest = attend(places[0][0], places[0][1])
  await sleepAsync(200)
  discard guest.say(kitchen, bl"(order soup)")
  await sleepAsync(150)
  let first = heard.counts
  discard guest.say(kitchen, bl"(order soup)")
  await sleepAsync(150)
  let
    again = toSeq(0 ..< n).mapIt(heard.counts[it] - first[it])
    lines = bridges.mapIt(it.carried).foldl(a + b, 0) +
            fabric.mapIt(it.carried[0] + it.carried[1]).foldl(a + b, 0)
    kind = if mesh: bl"mesh" else: bl"ring"
    s = sym($scheme)
  echo bl"(measured $s ($kind $n) {lines: $lines first: $first again: $again})"

let args = commandLineParams()
if args.len < 1: quit "schemes plain|digest|hops|gates [N] [mesh]"
let
  scheme = parseEnum[Scheme](args[0])
  n = if args.len > 1 and args[1][0].isDigit: args[1].parseInt else: 3
waitFor main(scheme, n, "mesh" in args)
