import std/[algorithm, sequtils, sysrand, times]
import bassline, bassline_crypto
import ./[edge, readers]

refuseWith BasslineError

type
  Jam* = ref object of SignedTrack
    key: Keypair
    held: BSet

  Server* = ref object of Monitor
    ranks: SortedTable[Node, seq[int]]
    asking: SortedTable[Node, seq[Line]]

  Line* = ref object of SignedTrack
    server: Server
    conn: Conn

  Lines* = ref object of Monitor
    jam*: Jam
    server: Server

proc now(): Node =
  Num(int64(epochTime() * 1000))

proc gone(jam: Jam, id: sink Node) =
  let at = now()
  jam.add jam.key.put(goneQ, bl"!{(by $id) (at $at)}")

method keeps*(self: Jam, n: Node): bool =
  if n in self.held or not procCall keeps(SignedTrack(self), n):
    return false
  matchValue n:
  of "(signed ($_ $_) $_)": true
  else: false

method added*(self: Jam, i: int, entry: Entry) =
  case entry
  of Present(n):
    self.held.incl n
  of Absent:
    discard

proc file(self: Server, n: Node, i: int) =
  matchValue n:
  of "(signed ($q $_) $_)":
    if q in self.ranks:
      self.ranks[q].insert(i, self.ranks[q].lowerBound(i))
    else:
      self.ranks[q] = @[i]
  else:
    discard

method joined*(self: Server) =
  for i in 0 ..< self.track.len:
    case self.track[i]
    of Present(n):
      self.file(n, i)
    of Absent:
      discard

method added*(self: Server, i: int, entry: Entry) =
  # each answer is filed under its question as it is kept, and told to the
  # lines asking it that can still be told
  case entry
  of Present(n):
    self.file(n, i)
    matchValue n:
    of "(signed ($q $_) $_)":
      if q in self.asking:
        self.asking[q].keepItIf(not it.conn.isClosed)
        let rank = Num(i)
        let told = bl"($q $rank $n)"
        for line in self.asking[q]:
          line.conn.write told
    else:
      discard
  of Absent:
    discard

method revised*(self: Server, swaps: openArray[Swap]) =
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
    case self.track[s.idx]
    of Present(n):
      self.file(n, s.idx)
    of Absent:
      discard

proc ask(self: Server, line: Line, q: Node) =
  # a line is told what is filed under the question, then each answer as it
  # is kept, and asking again tells it nothing more
  if q in self.asking and line in self.asking[q]:
    return
  if q in self.ranks:
    for r in self.ranks[q]:
      case self.track[r]
      of Present(a):
        let rank = Num(r)
        line.conn.write bl"($q $rank $a)"
      of Absent:
        discard
  if q in self.asking:
    self.asking[q].add line
  else:
    self.asking[q] = @[line]

proc asks(self: Server, line: Line): bool =
  for lines in self.asking.items:
    if line in lines:
      return true

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
    matchValue n:
    of "(signed ($q) $_)":
      self.server.ask(self, q)
    else:
      self.server.track.add n
  of Absent:
    discard

method joined*(self: Lines) =
  if self.server.isNil:
    self.server = Server()
    self.jam.up self.server
  for i in 0 ..< self.track.len:
    self.added(i, self.track[i])

method added*(self: Lines, i: int, entry: Entry) =
  case entry
  of Present(n):
    let conn = n.connection
    if not conn.isNil:
      conn.into = Line(server: self.server, conn: conn)
  of Absent:
    discard

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
          if not self.server.asks(line):
            conn.close
      of Absent:
        discard

proc newJam*(name: sink Node, key: sink Keypair): Jam =
  # a jam begins by saying which jam it is, at its first rank
  result = Jam(key: key)
  var id = newString(16)
  guard urandom(id.toOpenArrayByte(0, id.high)), "no randomness for the jam's id"
  let (idNode, at) = (Bytes(id), now())
  result.add result.key.put(jamQ, bl"!{(identity $name) (identity $idNode) (at $at)}")

method reified*(self: Jam): Value =
  # what a jam keeps, in rank order. Nothing in a jam is vacated, and a slot
  # that was would leave its rank nothing to stand at
  var kept: seq[Node]
  for i in 0 ..< self.len:
    case self[i]
    of Present(n):
      kept.add n
    of Absent:
      refuse "a jam's slots are never vacated, and slot " & $i & " is"
  let answers = List(kept)
  toValue bl"!(jam $answers)"

proc isReifiedJam*(self: Node): bool =
  matchValue self:
  of "!(jam $answers)":
    answers.isKind(bList, unmarked)
  else: false

proc bindJam*(n: var Node, key: sink Keypair) =
  # what a jam reified becomes that jam again, the same at the same ranks, and
  # whoever it held as here is gone, since no line reaches them yet. Its
  # answers are moved into the jam, so a value refused partway is left partly
  # taken
  guard n.isReifiedJam, "not a jam as it reifies, !(jam [ANSWER …])"
  let jam = Jam(key: key)
  for i in 0 ..< n[1].asValue.len:
    var answer = move n.asValue.vseq[1].asValue.vseq[i]
    var begins = false
    matchValue answer:
    of "(signed (jam $_) $_)": begins = true
    else: discard
    guard (i > 0 or begins) and jam.add(move answer) == Contribution.Kept,
      "a jam keeps a signed answer that holds at each rank, its (jam) first, and not at " & $i
  var ids = jam.who
  for id in ids.mitems:
    jam.gone(move id)
  n = jam.toNode

proc toJam*(n: sink Node, key: sink KeyPair): Node =
  result = n
  result.bindJam(key)
