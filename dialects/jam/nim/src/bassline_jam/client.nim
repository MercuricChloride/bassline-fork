import bassline, bassline_crypto

type Client* = ref object of SignedTrack
  ranks: SortedTable[int, int]
  conflicts*: Track

method keeps*(self: Client, n: Node): bool =
  # a record a jam told, its answer one a signed track keeps and put to the
  # question it is told under. Each rank is held once: told again the same it
  # is ignored, and told otherwise it is a conflict, kept apart
  matchValue n:
  of "($q $r (signed ($asked $_) $_))":
    if asked != q or not r.isKind(bNum, unmarked) or not r.asValue.vnum.isInt or
       r.asValue.vnum.asInt < 0 or not procCall keeps(SignedTrack(self), n[2]):
      return false
    let rank = r.asValue.vnum.asInt
    if rank notin self.ranks:
      return true
    case self[self.ranks[rank]]
    of Present(held):
      if held != n and not self.conflicts.isNil:
        self.conflicts.add bl"(conflict $held $n)"
    of Absent:
      discard
    false
  else:
    false

method added*(self: Client, i: int, entry: Entry) =
  case entry
  of Present(n):
    self.ranks[n[1].asValue.vnum.asInt] = i
  of Absent:
    discard
