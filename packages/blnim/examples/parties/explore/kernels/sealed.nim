## A party where what is said into a name reaches whoever goes by it and
## nobody else: each connection owns its name. At the stock party anyone
## who says (sub S) for a name S hears what is said to it.
import std/[sysrand, tables]
import bl/core
import ./kernel

type Sealed* = ref object of Party

method arrived(p: Sealed, s: Seat) =
  p.owners[s.name.ce.toString] = s
  s.owns.add s.name

proc sealed*(): Sealed =
  let order = bytes(urandom 16)
  Sealed(name: bl"(sealed $order)")

when isMainModule:
  sealed().serve.announce
  runForever()
