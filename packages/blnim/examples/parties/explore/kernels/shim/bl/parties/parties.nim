## bl/parties/parties as a program that serves its own party sees it,
## with `serve` giving the kernel named in KERNEL on [::1] at a port of
## its own, and `attend` attending it there. Compiled with this folder's
## parent on the path ahead of src, an example runs unchanged against
## any kernel.
import std/[os, sysrand]
import bl/core
import ../../stock_parties as stock
import ../../../[kernel, sealed, veiled, gated, recorder, fence]

export stock except serve, attend, Party, port

type Served* = ref object
  close: proc()

var at = Port(0)

proc close*(s: Served) = s.close()

proc serve*(): Served =
  let k = getEnv("KERNEL", "stock")
  case k
  of "stock":
    let p = stock.serve(parseIpAddress("::1"), Port(0))
    at = stock.port(p)
    return Served(close: proc() = stock.close(p))
  of "fence":
    let p = stock.serve(parseIpAddress("::1"), Port(0))
    let l = fence((parseIpAddress("::1"), stock.port(p)),
                  readValue(getEnv("TOPICS", "{status (kitchen) (desk)}")))
    at = l.getLocalAddr[1]
    return Served(close: proc() = l.close)
  else: discard
  let p: kernel.Party =
    case k
    of "base": kernel.Party().serve
    of "sealed": sealed().serve
    of "veiled": veiled().serve
    of "gated": gated(readValue(getEnv("TOPICS", "{status (kitchen) (desk)}"))).serve
    of "recorder": recorder(getEnv("LOG")).serve
    else: quit "no kernel " & k
  at = p.port
  Served(close: proc() = kernel.close(p))

proc attend*(owns: seq[Value] = @[]): Attendee =
  stock.attend(parseIpAddress("::1"), at, owns)
