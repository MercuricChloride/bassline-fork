## bl jam scan: the places on this machine's networks where something
## takes a connection, and what each says when asked (jam)
##
## Every address on each network this machine is on (its own among
## them), or on the networks given, is tried on each port. Where a
## connection is taken it is asked (jam), signed as `bl jam` signs, and
## whatever it says first comes back with the place. A jam says which jam
## it is; anything else may say nothing.

import std/[asyncdispatch, asyncnet, nativesockets, options, posix, sequtils,
            strutils, sugar, terminal, times]
import harness, jam_client
import bl/core
import bl/lib/jam

type
  IfAddrs {.importc: "struct ifaddrs", header: "<ifaddrs.h>",
            incompleteStruct.} = object
    ifa_next: ptr IfAddrs
    ifa_name: cstring
    ifa_flags: cuint
    ifa_addr: ptr SockAddr
    ifa_netmask: ptr SockAddr

  Net* = tuple[base: uint32, bits: int]
    ## a network, its address in host order and the length of its prefix

  Found = object
    open: bool            ## whether a connection was taken
    told: Option[Value]   ## the first value said back, if one came

proc getifaddrs(ifap: ptr ptr IfAddrs): cint {.importc, header: "<ifaddrs.h>".}
proc freeifaddrs(ifa: ptr IfAddrs) {.importc, header: "<ifaddrs.h>".}

var
  IFF_UP {.importc, header: "<net/if.h>".}: cuint
  IFF_LOOPBACK {.importc, header: "<net/if.h>".}: cuint

const
  Widest = 24
    ## a network wider than this is looked at only in the /24 around
    ## this machine's address on it
  MostAddresses = 4096
    ## the most addresses a network given with --net may hold
  AtOnce = 96
    ## connections tried at once, well under a shell's usual limit on
    ## open files

proc ipv4(a: ptr SockAddr): uint32 =
  ## an IPv4 address, in host order
  nativesockets.ntohl(cast[ptr Sockaddr_in](a).sin_addr.s_addr)

proc spelled(address: uint32): string =
  [address shr 24, (address shr 16) and 255, (address shr 8) and 255,
   address and 255].mapIt($it).join(".")

proc prefix(mask: uint32): int =
  var m = mask
  while (m and 0x8000_0000'u32) != 0:
    inc result
    m = m shl 1

proc network(address: uint32, bits: int): Net =
  let mask = if bits == 0: 0'u32 else: not ((1'u32 shl (32 - bits)) - 1)
  (address and mask, bits)

proc `$`*(n: Net): string = spelled(n.base) & "/" & $n.bits

proc networksHere*(): seq[Net] =
  ## the IPv4 networks this machine is on, loopback aside, each narrowed
  ## to the /24 around its address when it is wider. Raises if they
  ## can't be listed
  var all: ptr IfAddrs
  if getifaddrs(addr all) != 0:
    raise newException(OSError, "can't list this machine's networks: " & $strerror(errno))
  defer: freeifaddrs(all)
  var at = all
  while at != nil:
    let i = at[]
    at = i.ifa_next
    if i.ifa_addr == nil or i.ifa_netmask == nil or
       cint(i.ifa_addr.sa_family) != posix.AF_INET or
       (i.ifa_flags and IFF_UP) == 0 or (i.ifa_flags and IFF_LOOPBACK) != 0:
      continue
    let address = ipv4(i.ifa_addr)
    var bits = prefix(ipv4(i.ifa_netmask))
    if bits < Widest:
      chatter $i.ifa_name & " is on " & $network(address, bits) &
        ", wider than /" & $Widest & ": looking only at " &
        $network(address, Widest) & " (--net says otherwise)"
      bits = Widest
    let n = network(address, bits)
    if n notin result: result.add n

proc parseNet*(s: string): Net =
  ## A.B.C.D/N, or A.B.C.D alone for that one address. Raises if it is
  ## neither, or holds more than MostAddresses
  let (spelledAddress, bitsText) =
    if '/' in s: (s.split('/', 1)[0], s.split('/', 1)[1]) else: (s, "32")
  let parts = spelledAddress.split('.')
  var address = 0'u32
  var bits = 0
  try:
    if parts.len != 4: raise newException(ValueError, "")
    for p in parts:
      let n = parseInt(p)
      if n < 0 or n > 255: raise newException(ValueError, "")
      address = (address shl 8) or uint32(n)
    bits = parseInt(bitsText)
    if bits < 0 or bits > 32: raise newException(ValueError, "")
  except ValueError:
    raise newException(ValueError, "a network is A.B.C.D/N or A.B.C.D, not " & s)
  if (1 shl (32 - bits)) > MostAddresses:
    raise newException(ValueError, s & " holds more than " & $MostAddresses & " addresses")
  network(address, bits)

proc addresses(n: Net): seq[uint32] =
  ## the addresses on a network that a machine may have: all but the
  ## network's own and its broadcast, where it has them
  let size = 1'u32 shl (32 - n.bits)
  if size <= 2:
    for i in 0'u32 ..< size: result.add n.base + i
  else:
    for i in 1'u32 ..< size - 1: result.add n.base + i

proc probe(host: string, port: Port, ask: string, wait: int): Future[Found] {.async.} =
  ## a connection to the place, and, if one is taken and there is
  ## something to ask, the first value said back within `wait` ms
  let s = newAsyncSocket(buffered = false)
  try:
    if not await s.connect(host, port).withTimeout(wait):
      return
    result.open = true
    if ask.len == 0:
      return
    await s.send(ask)
    var d = newDecoder()
    let until = epochTime() + wait / 1000
    while result.told.isNone:
      let left = int((until - epochTime()) * 1000)
      if left <= 0: break
      let got = s.recv(16 * 1024)
      if not await got.withTimeout(left): break
      let data = got.read
      if data.len == 0: break
      d.buf.add(data.toBytes)
      for view in d.checked:
        if result.told.isNone: result.told = some view.toValue
  except CatchableError:
    discard # nothing there, or nothing it said reads: the place is still told as open
  finally:
    # a connection given up on may have failed and been closed already
    try: s.close()
    except CatchableError: discard

proc scan*(nets: seq[Net], ports: seq[Port], ask: string, wait: int,
           found: (Value) -> void): Future[int] {.async.} =
  ## tries every address on `nets` on each of `ports`, AtOnce at a time,
  ## and gives `found` (found "HOST:PORT" TOLD) for each place that takes
  ## a connection, TOLD the first value said back to `ask`, when one
  ## comes. Answers how many places took one
  var places: seq[(string, Port)]
  for n in nets:
    for address in addresses(n):
      for port in ports:
        places.add (spelled(address), port)
  var answered = 0
  proc look(host: string, port: Port) {.async.} =
    let told = await probe(host, port, ask, wait)
    if not told.open: return
    inc answered
    let at = text(host & ":" & $port)
    found initRec(@[sym"found", at] & (if told.told.isSome: @[told.told.get] else: @[]))
  var i = 0
  while i < places.len:
    let batch = places[i ..< min(i + AtOnce, places.len)]
    await all(batch.mapIt(look(it[0], it[1])))
    i += AtOnce
  answered

proc run*(t: Tool, a: Args) =
  var ports: seq[Port]
  for p in (if a.positional.len > 0: a.positional else: @["8455", "8456"]):
    try:
      let n = parseInt(p)
      if n < 1 or n > 65535: raise newException(ValueError, "")
      ports.add Port(n)
    except ValueError:
      t.misuse "a port is a number from 1 to 65535, not " & p
  let nets =
    if a.has("net"):
      a.every("net").mapIt(try: parseNet(it) except ValueError as e: t.misuse "--net: " & e.msg)
    else:
      try: networksHere() except OSError as e: fail e.msg
  if nets.len == 0:
    fail "this machine is on no network but loopback (--net names one)"
  let wait = t.intOpt(a, "wait", 500, lo = 1)
  let ask =
    if a.has("silent"): ""
    else: t.speakerFrom(a, signs = true).ask(JamQ).ce.toString
  if stdout.isatty:
    chatter "what is found is written as CE: bl jam scan | bl cat reads it"
  chatter "looking on " & nets.mapIt($it).join(", ") & ", port" &
    (if ports.len > 1: "s " else: " ") & ports.mapIt($it).join(" ")
  let answered = waitFor scan(nets, ports, ask, wait, (v: Value) => emit v)
  chatter $answered & " place(s) took a connection"
