import std/sequtils
import bassline, bassline_crypto

blet"""{
  jam-q      : jam
  here-q     : here
  gone-q     : gone
  by-q       : by
  at-q       : at
  identity-q : identity}"""

proc isObject*(n: Node): bool =
  n.isKind(bSet, marked)

iterator answers*(obj, q: Node): lent Node =
  if obj.isObject:
    for each in obj.asValue.vset:
      matchValue each:
      of "($h $_)":
        if h == q:
          yield each[1]
      else:
        discard

iterator identities*(id: Node): lent Node =
  if id.isObject:
    for each in id.asValue.vset:
      matchValue each:
      of "(identity $_)":
        yield each[1]
      else:
        discard
  else:
    yield id

proc knownAs*(id, name: Node): bool =
  for each in id.identities:
    if each == name:
      return true

proc sharesIdentity*(a, b: Node): bool =
  for name in a.identities:
    if b.knownAs(name):
      return true

proc put*(kp: Keypair, q, a: sink Node): Node =
  kp.signed(bl"($q $a)").toNode

proc ask*(kp: Keypair, q: sink Node): Node =
  kp.signed(bl"($q)").toNode

proc who*(t: Track): seq[Node] =
  # those said to be here and not since said to be gone, by any name they
  # share, over the answers a track keeps or the records a jam told it
  template saw(q, a: Node) =
    if q == hereQ or q == goneQ:
      for id in a.answers(byQ):
        result.keepItIf(not it.sharesIdentity(id))
        if q == hereQ:
          result.add id
  for i in 0 ..< t.len:
    case t[i]
    of Present(n):
      matchValue n:
      of "(signed ($q $a) $_)":
        saw(q, a)
      of "($_ $_ (signed ($q $a) $_))":
        saw(q, a)
      else:
        discard
    of Absent:
      discard
