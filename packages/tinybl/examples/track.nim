import tinybl/[micro, micro_macros, text, tracks]

type
  Logger = ref object of Monitor

method added(self: Logger, i: int, entry: Entry) =
  echo "added: ", entry

method removed(self: Logger, i: int, entry: Entry) =
  echo "removed: ", entry

method changed(self: Logger, i: int, prev, curr: Entry) =
  echo "changed: ", prev, " to ", curr

method beforeReset*(self: Logger) =
  echo "before reset: ", self.track[0..<self.track.len]

method afterReset*(self: Logger) =
  echo "after reset: ", self.track[0..<self.track.len]

method joined(self: Logger) =
  echo "joined:"

method left(self: Logger, t: Track) =
  echo "left: "

proc main =
  let
    track = Track()
    log = Logger()

  log.track = track

  track.add bl"hello"
  track.add bl"world"

  track.delete 0

  track.update 1, bl"[hello world]"

  track.clear

when isMainModule:
  main()
