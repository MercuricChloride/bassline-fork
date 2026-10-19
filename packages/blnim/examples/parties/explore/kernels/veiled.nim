## A party that hides who said what. A speaker goes by a veil in each
## topic it says into, sixteen bytes no one else can work out, the same
## each time it says into that topic. Saying into a veil reaches whoever
## wears it, told as said into its own name, so an answer finds its way
## and nobody learns a name from it.
import std/[sequtils, sysrand, tables]
import bl/core
import bl/lib/crypto/digest
import ./kernel

type Veiled* = ref object of Party
  secret: Value
  veils: Table[string, Seat]  ## who wears each veil, by its CE

method by(p: Veiled, s: Seat, t: Value): Value =
  let (secret, name) = (p.secret, s.name)
  result = bytes(blake2b(bl"(veil $secret $name $t)".ce)[0 ..< 16])
  p.veils[result.ce.toString] = s

method into(p: Veiled, s: Seat, t: Value): Value =
  let wearer = p.veils.getOrDefault(t.ce.toString)
  if wearer.isNil: t else: wearer.name

method left(p: Veiled, s: Seat) =
  for k in toSeq(p.veils.keys):
    if p.veils[k] == s: p.veils.del k

proc veiled*(): Veiled =
  let order = bytes(urandom 16)
  Veiled(name: bl"(veiled $order)", secret: bytes(urandom 32))

when isMainModule:
  veiled().serve.announce
  runForever()
