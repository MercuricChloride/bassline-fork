import ./[micro, micro_macros, text, tracks]

type
  Printer* = ref object of Monitor
    to*: File

  Relay* = ref object of Monitor
    into*: Track

proc toNode(entry: Entry): Node =
  case entry
  of Present(n): bl"(present $n)"
  of Absent: bl"Absent"

method added*(self: Printer, i: int, entry: Entry) =
  # what a track held before it joined isn't a change, so isn't printed
  let to = if self.to.isNil: stdout else: self.to
  case entry
  of Present(n):
    let at = Num(i)
    to.writeLine $bl"(added $at $n)"
  of Absent:
    discard

method revised*(self: Printer, swaps: openArray[Swap]) =
  let to = if self.to.isNil: stdout else: self.to
  for s in swaps:
    let (at, was, now) = (Num(s.idx), s.entry.toNode, self.track[s.idx].toNode)
    to.writeLine $bl"(revised $at $was $now)"

# a revision is the holder's own, so only what was added is relayed
method added*(self: Relay, i: int, entry: Entry) =
  case entry
  of Present(n): self.into.add n
  of Absent: discard

method joined*(self: Relay) =
  for i in 0 ..< self.track.len:
    self.added(i, self.track[i])
