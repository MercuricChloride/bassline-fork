import bassline
import ./signatures

type
  Checked* = ref object of Live
    said: Signed

  SignedTrack* = ref object of Track

  Checker* = ref object of Monitor
    into*: Track

proc checked*(s: sink Signed): Checked =
  if s.holds:
    result = Checked(said: s)

proc checked*(n: sink Node): Checked =
  case n
  of Bound(l):
    if l of Checked:
      result = Checked(l)
  of Plain:
    let s =
      try: n.reified.toSigned
      except BasslineError: return nil
    result = checked(s)

proc holds*(n: Node): bool =
  # what a plain value holds isn't copied to check it. A value with live parts
  # is checked by what it stands for
  case n
  of Bound(l):
    l of Checked
  of Plain:
    if not n.isPure:
      return n.reified.holds
    matchValue n:
    of "(signed $v $sig)":
      try: sig.toSignature.holds(v)
      except BasslineError: false
    else:
      false

proc value*(c: Checked): lent Node =
  c.said.value

proc signature*(c: Checked): lent Signature =
  c.said.sig

proc key*(c: Checked): PublicKey =
  c.said.sig.publicKey

proc signed*(c: Checked): lent Signed =
  c.said

method reified*(c: Checked): Value =
  c.said.toNode.toValue

method keeps*(self: SignedTrack, n: Node): bool =
  n.holds

method added*(self: Checker, i: int, entry: Entry) =
  case entry
  of Present(n):
    let c = n.checked
    if not c.isNil:
      self.into.add c.toNode
  of Absent:
    discard

method joined*(self: Checker) =
  for i in 0 ..< self.track.len:
    self.added(i, self.track[i])

method revised*(self: Checker, swaps: openArray[Swap]) =
  # a slot made live in place stands for what it held, and isn't offered again
  for s in swaps:
    case self.track[s.idx]
    of Present(n):
      case s.entry
      of Present(was):
        if was.reified != n.reified:
          self.added(s.idx, self.track[s.idx])
      of Absent:
        self.added(s.idx, self.track[s.idx])
    of Absent:
      discard
