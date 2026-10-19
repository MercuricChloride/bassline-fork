## Parties on [::1] standing in for machines, a gate at each, and bridges
## between them in a ring (or every pair, `mesh`). Programs attend their
## own party only: a listener at each hears (kitchen), a guest at the
## first party orders there, signed with its own key, and a cook at the
## party farthest round the ring answers into what the order was said by.
##
##   ring [N] [mesh]   N parties, 3 unless given
##
## It finds each party by what it says first, bridges one party to itself
## to see that bridge close, and prints what everyone heard and how many
## lines each bridge carried. Then it closes one bridge and orders again,
## and lets the guest go and counts the seats the gates still hold.

import std/[os, sequtils, strutils, tables]
import bl/core
import bl/lib/crypto/clave
import std/sysrand
import ./fabric

let
  here = parseIpAddress("::1")
  kitchen = bl"(kitchen)"

proc shown(v: Value): string =
  ## a value, with its bytes and signatures cut short
  matchValue v:
  of "(signed $x $_)": "(signed " & $x & " …)"
  else:
    if v.kind == bBytes: ($v)[0 .. 9] & "…" else: $v

type Listener = ref object
  at: int
  heard: seq[Value]

proc listen(l: Listener, a: Attendee) {.async.} =
  a.each msg:
    if msg.topic == kitchen:
      l.heard.add msg.value
      echo "  party ", l.at, " heard ", msg.value.shown, " by ", msg.by.shown

proc cook(a: Attendee) {.async.} =
  ## answers each order into what it was said by, once the signature holds
  a.each msg:
    if msg.topic != kitchen: continue
    let order = try: Signed.fromValue(msg.value) except BasslineError: continue
    if order.holds:
      let what = order.value
      echo "  the cook checked the signature and answers ", msg.by.shown
      discard a.say(msg.by, bl"(served $what)")

proc guest(a: Attendee, kp: Keypair, dish: string): Future[void] {.async.} =
  ## orders, and waits for what is said into its name
  a.say(kitchen, kp.signed(bl"(order $dish)").toValue)
  a.each msg:
    if msg.topic == a.name and msg.by.kind != bNil:
      echo "  the guest heard ", msg.value, " by ", msg.by.shown
      return

proc counts(bridges: seq[Bridge], gates: seq[Gate]) =
  for i, b in bridges:
    echo "  bridge ", i, " carried ", b.carried[0], " one way and ", b.carried[1], " back"
  echo "  lines carried: ", bridges.mapIt(it.carried[0] + it.carried[1]).foldl(a + b, 0)
  echo "  gates admitted ", gates.mapIt(it.admitted), " and dropped ", gates.mapIt(it.dropped)
  for b in bridges: b.carried = [0, 0]
  for g in gates: (g.admitted, g.dropped) = (0, 0)

proc main(n: int, mesh: bool) {.async.} =
  let
    parties = (0 ..< n).mapIt(serve(here, Port(0)))
    places = parties.mapIt((here, it.port))
  for p in places:
    echo "found a party at [", p[0], "]:", p[1], " going by ", (await probe(p[0], p[1])).shown
  let
    gates = places.mapIt(gate(it[0], it[1], @[kitchen]))
    loop = bridge(places[0], places[0])
  var bridges: seq[Bridge]
  for i in 0 ..< n:
    for j in i + 1 ..< n:
      if mesh or j == i + 1 or (i == 0 and j == n - 1 and n > 2):
        bridges.add bridge(places[i], places[j])
  var listeners: seq[Listener]
  for i, p in places:
    let (l, a) = (Listener(at: i), attend(p[0], p[1]))
    a.sub kitchen
    listeners.add l
    asyncCheck l.listen(a)
  let
    far = n div 2
    chef = attend(places[far][0], places[far][1])
    diner = attend(places[0][0], places[0][1])
  var seed: Seed
  doAssert urandom(seed)
  let kp = keypairFromSeed(seed)
  chef.sub kitchen
  asyncCheck cook(chef)
  await sleepAsync(200)
  echo n, " parties, ", bridges.len, " bridges, ", (if mesh: "every pair" else: "a ring"),
    ". The guest is at party 0, the cook at party ", far
  echo "a bridge from party 0 to itself has ", (if loop.isClosed: "closed" else: "not closed")

  echo "the guest orders soup"
  await diner.guest(kp, "soup")
  await sleepAsync(100)
  counts(bridges, gates)
  echo "  each party heard the order ", listeners.mapIt(it.heard.len), " times"
  echo "  connections: ", n, " gates, ", 2 * bridges.len, " bridge ends, ",
    gates.mapIt(it.seats.len).foldl(a + b, 0), " seats"

  echo "bridge 0 goes, and the guest orders bread"
  bridges[0].close
  for l in listeners: l.heard.setLen 0
  await diner.guest(kp, "bread")
  await sleepAsync(100)
  counts(bridges, gates)
  echo "  each party heard the order ", listeners.mapIt(it.heard.len), " times"

  echo "the guest goes"
  echo "  seats held before: ", gates.mapIt(it.seats.len)
  diner.close
  await sleepAsync(100)
  echo "  seats held after: ", gates.mapIt(it.seats.len)

let
  n = if paramCount() > 0 and paramStr(1)[0].isDigit: paramStr(1).parseInt else: 3
  mesh = "mesh" in commandLineParams()
waitFor main(n, mesh)
