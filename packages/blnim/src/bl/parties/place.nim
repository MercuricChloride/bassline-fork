##[
  The place of a value: an IPv6 address in fd00::/8, the unique local
  addresses a machine assigns itself, whose other 120 bits are the
  first 120 of the blake2b-256 of the value's CE. Every machine reckons
  the same place for a value, and on each it is wherever that machine
  has put it.
]##
import std/net
import ../core
import ../lib/crypto/digest

proc placeOf*(v: Value): IpAddress =
  ## the place of `v`
  let h = blake2b(v.ce)
  result = IpAddress(family: IPv6)
  result.address_v6[0] = 0xfd
  result.address_v6[1 .. 15] = h[0 .. 14]
