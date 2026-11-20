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
