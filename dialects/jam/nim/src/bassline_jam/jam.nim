import std/[algorithm, os, sequtils, sysrand, times]
import bassline, bassline_crypto
import ./[edge, readers]

refuseWith BasslineError

type
  Jam* = ref object of SignedTrack
    key: Keypair
    held: BSet
    log: string
    ranks: SortedTable[Node, seq[int]]
    asking: SortedTable[Node, seq[Line]]

  Line* = ref object of SignedTrack
    jam: Jam
    conn: Conn

  Lines* = ref object of Monitor
    jam*: Jam

proc told(q, r, a: Node): string =
  result.writeOpen(bRec, false)
  q.write(result)
  r.write(result)
  a.write(result)
  result.writeClose

proc now(): Node =
  Num(int64(epochTime() * 1000))

proc gone(jam: Jam, id: sink Node) =
  let at = now()
  jam.add jam.key.put(goneQ, bl"!{(by $id) (at $at)}")

proc who*(t: Track): seq[Node] =
  # those said to be here and not since said to be gone, by any name they share
  for i in 0 ..< t.len:
    case t[i]
    of Present(n):
      matchValue n:
      of "(signed ($q $a) $_)":
        if q == hereQ or q == goneQ:
          for id in a.answers(byQ):
            result.keepItIf(not it.sharesIdentity(id))
            if q == hereQ:
              result.add id
      else:
        discard
    of Absent:
      discard

proc file(jam: Jam, n: Node, i: int) =
  matchValue n:
  of "(signed ($q $_) $_)":
    if q in jam.ranks:
      jam.ranks[q].insert(i, jam.ranks[q].lowerBound(i))
    else:
      jam.ranks[q] = @[i]
  else:
    discard

method keeps*(self: Jam, n: Node): bool =
  # the log is written before the answer is kept, so a rank is spent only on
  # what the log took
  if n in self.held or not procCall keeps(SignedTrack(self), n):
    return false
  matchValue n:
  of "(signed ($q $_) $_)":
    if self.log.len == 0:
      return true
    let record = told(q, Num(self.len), n)
    try:
      let f = open(self.log, fmAppend)
      defer: f.close
      f.write record
      f.flushFile
      result = true
    except IOError, OSError:
      result = false
  else:
    result = false

method added*(self: Jam, i: int, entry: Entry) =
  # each answer is filed under its question as it is kept, and told to the
  # lines asking it that can still be told
  case entry
  of Present(n):
    self.held.incl n
    self.file(n, i)
    matchValue n:
    of "(signed ($q $_) $_)":
      if q in self.asking:
        self.asking[q].keepItIf(not it.conn.isClosed)
        let record = told(q, Num(i), n)
        for line in self.asking[q]:
          line.conn.send record
    else:
      discard
  of Absent:
    discard

method revised*(self: Jam, swaps: openArray[Swap]) =
  # the index follows a revision, though no line is told of it
  for s in swaps:
    case s.entry
    of Present(was):
      matchValue was:
      of "(signed ($q $_) $_)":
        if q in self.ranks:
          self.ranks[q].keepItIf(it != s.idx)
      else:
        discard
    of Absent:
      discard
    case self[s.idx]
    of Present(n):
      self.file(n, s.idx)
    of Absent:
      discard

method keeps*(self: Line, n: Node): bool =
  if not procCall keeps(SignedTrack(self), n):
    return false
  matchValue n:
  of "(signed ($_) $_)":
    true
  of "(signed ($q $_) $_)":
    q != jamQ
  else:
    false

method added*(self: Line, i: int, entry: Entry) =
  case entry
  of Present(n):
    let jam = self.jam
    matchValue n:
    of "(signed ($q) $_)":
      if q in jam.asking and self in jam.asking[q]:
        return
      if q in jam.ranks:
        for r in jam.ranks[q]:
          case jam[r]
          of Present(a):
            self.conn.send told(q, Num(r), a)
          of Absent:
            discard
      if q in jam.asking:
        jam.asking[q].add self
      else:
        jam.asking[q] = @[self]
    else:
      jam.add n
  of Absent:
    discard

method added*(self: Lines, i: int, entry: Entry) =
  case entry
  of Present(n):
    let conn = n.connection
    if not conn.isNil:
      conn.into = Line(jam: self.jam, conn: conn)
  of Absent:
    discard

method joined*(self: Lines) =
  for i in 0 ..< self.track.len:
    self.added(i, self.track[i])

method revised*(self: Lines, swaps: openArray[Swap]) =
  # a connection no longer held says nothing more, so whoever it said was here
  # is gone. It is told on while it asks anything, since a pipe may stop
  # speaking and go on hearing
  for s in swaps:
    case self.track[s.idx]
    of Present:
      discard
    of Absent:
      case s.entry
      of Present(n):
        let conn = n.connection
        if not conn.isNil and conn.into of Line:
          let line = Line(conn.into)
          var ids = line.who
          for id in ids.mitems:
            self.jam.gone(move id)
          var asks = false
          for lines in self.jam.asking.items:
            asks = asks or line in lines
          if not asks:
            conn.close
      of Absent:
        discard

proc load(jam: Jam, path: string) =
  # a record cut short, as by a crash partway through appending it, is cut
  # from the file, so what is appended next starts clean
  let bytes = readFile(path)
  var
    reader = initReader()
    pos, whole = 0
  while reader.readCE(bytes, pos):
    whole = pos
    var record = toNode(move reader.value)
    matchValue record:
    of "($q $r (signed ($asked $_) $_))":
      let rank = jam.len
      guard r == Num(rank) and asked == q and (rank > 0 or q == jamQ) and
        jam.add(move record.asValue.vseq[2]) == Contribution.Kept,
        path & " holds what a jam doesn't keep at rank " & $rank &
          ": unsigned, signed in a scheme it can't check, out of order, or not begun by its (jam)"
    else:
      refuse path & " holds what isn't a record a jam tells: " & $record
  if whole < bytes.len:
    writeFile(path, bytes[0 ..< whole])

proc newJam*(name: sink Node, key: sink Keypair, log: sink string = ""): Jam =
  # a jam begins by saying which jam it is, and whoever its log says is here
  # is gone, since no line reaches them yet
  result = Jam(key: key)
  if log.len > 0:
    if fileExists(log):
      result.load(log)
    result.log = log
  if result.len == 0:
    var id = newString(16)
    guard urandom(id.toOpenArrayByte(0, id.high)), "no randomness for the jam's id"
    let (idNode, at) = (Bytes(id), now())
    guard result.add(result.key.put(jamQ, bl"!{(identity $name) (identity $idNode) (at $at)}")) ==
      Contribution.Kept, "can't keep the jam in " & result.log
  var ids = result.who
  for id in ids.mitems:
    result.gone(move id)
