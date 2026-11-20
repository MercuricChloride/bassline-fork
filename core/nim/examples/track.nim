import std/os
import bassline

refuseWith BasslineError

type Logger = ref object of Monitor

method reified*(self: Logger): Value =
  toValue bl"logger!"

method added(self: Logger, i: int, entry: Entry) =
  echo "added: ", entry

method revised(self: Logger, swaps: openArray[Swap]) =
  echo "changed:"
  for each in swaps:
    echo "  old: ", each.entry
    echo "  new: ", self.track[each.idx]

method joined(self: Logger) =
  echo "joined:"

method left(self: Logger, t: Track) =
  echo "left: "

type ToFile = ref object of Monitor
  path: string

proc flush*(self: ToFile, t: Track) =
  var payload = ""
  for i in 0 ..< t.len:
    let v = t[i]
    case v
    of Absent:
      discard
    of Present(v):
      v.reified.write(payload)
  self.path.expandFilename.writeFile(payload)

method reified*(self: ToFile): Value =
  let p = Sym self.path
  toValue bl"!(to-file $p)"

method revised*(self: ToFile, swaps: openArray[Swap]) =
  echo "flushing..."
  self.flush(self.track)

method left(self: ToFile, t: Track) =
  self.flush(t)

type
  PingPong = ref object of Monitor

method added*(self: PingPong, i: int, e: Entry) =
  case e
  of Present(v):
    if v == bl"ping":
      self.track.add bl"pong"
  else: discard

method reified*(self: PingPong): Value =
  toValue bl"ping-pong!"

proc main =
  let track = Track()

  track.up(Logger(), PingPong(), ToFile(path: "/tmp/writer-thang.blb"))

  track.add bl"hello"
  track.add bl"world"
  track.add bl"ping"

  track.reviseIt:
    for i in 0..<it.len:
      it.delete i
    it[1] = bl"world"
    it[3] = bl"[hello world]"

  try:
    track.reviseIt:
      it[0] = bl"boom"
      guard it[0] == Present(n: bl"boom"), "wat"
      guard false, "boom"
  except BasslineError as e:
    echo "error: ", e.msg

  echo "first after raising: ", track[0]

  echo "reified: \n", track.reified

  let other = Track()
  for m in track.attached:
    other.up(m)

  echo "reified after down: \n", track.reified

  echo "other reified: \n", other.reified

when isMainModule:
  main()
