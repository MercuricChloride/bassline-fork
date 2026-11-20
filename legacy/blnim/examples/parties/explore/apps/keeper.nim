##[
  keeper: owns a jam's rooms at a party on [::1], keeps each message
  said into them once with the jam's own rank, and catches up whoever
  asks.

    keeper PORT LOG ROOM …

  A room is the topic (room NAME), and the lobby is (room lobby). Each
  room is owned on a connection of its own, so a room can be opened at
  any time. Said into a room, which only the keeper hears:

    (post MSG)    keeps MSG in the room, once
    (here WHO)    keeps (here WHO S), S what the speaker goes by, and
                  (gone WHO S) once the party says S is dead
    (from R)      says the room's messages from rank R on into what the
                  speaker goes by, then (through ROOM R), R the jam's last
    (open NAME)   said into the lobby, owns (room NAME), and keeps
                  (opened NAME) in the lobby once the party has taken it

  What it keeps it says into the room as (kept ROOM R MSG BY), R the
  jam's rank and BY what the speaker went by, and appends to LOG, from
  which it begins again. Presence is the party's: on each connection
  the keeper keeps (gone WHO S) for every S the party doesn't say is
  alive.
]##
import std/[os, sequtils, strutils, sugar]
import bl/core
import bl/parties/parties
import bl/lib/bvarfile

blet"{status lobby}"

let
  port = Port(paramStr(1).parseInt)
  log = paramStr(2)
var
  told: seq[(Value, Value)]          # (ROOM (kept ROOM R MSG BY)), by rank
  kept = newBSet()                   # every (ROOM MSG), so each is kept once
  seats: seq[(Value, Value, Value)]  # (ROOM WHO S) for each here not gone
  rooms: seq[(Value, Attendee)]      # each room held, and its connection

proc remember(room, msg, rec: Value) =
  kept.incl bl"($room $msg)"
  told.add (room, rec)
  matchValue msg:
  of "(here $who $s)": seats.add (room, who, s)
  of "(gone $who $s)": seats.keepItIf(it != (room, who, s))
  else: discard

proc keep(room, msg, by: Value) =
  ## keeps `msg` in `room` unless it is kept there already, and says so
  if bl"($room $msg)" in kept: return
  let r = told.len
  let rec = bl"(kept $room $r $msg $by)"
  remember(room, msg, rec)
  discard log.appendValue rec
  echo rec
  for (held, a) in rooms:
    if held == room: a.say(bl"(room $room)", rec)

proc gone(room: Value, still: proc(s: Value): bool) =
  ## keeps (gone WHO S) for everyone here in `room` who isn't `still` here
  let sitting = seats
  for (r, who, s) in sitting:
    if r == room and not still(s): keep(room, bl"(gone $who $s)", s)

proc hold(room: Value) {.async.} =
  ## owns (room ROOM) on a connection of its own, and does what is said there
  if rooms.anyIt(it[0] == room): return
  let a = attend(parseIpAddress("::1"), port, owns = @[bl"(room $room)"])
  rooms.add (room, a)
  a.sub status
  var alive = newBSet()  # whom the party has said is here, on this connection
  a.each said:
    let (t, v, by) = (said.topic, said.value, said.by)
    matchValue bl"($t $v $by)":
    of "($_ (name $_) nil)":
      alive = newBSet()
      # outside the dialect, so the party says it back, and only once it
      # has taken the own and the subs said before it
      a.send bl"(settled)"
    of "($_ (invalid (settled)) nil)":
      gone(room, s => s in alive)
      if room != lobby: keep(lobby, bl"(opened $room)", null())
    of "(status (alive $s) nil)": alive.incl s
    of "(status (dead $s) nil)": gone(room, x => x != s)
    of "((room $_) (post $msg) $_)": keep(room, msg, by)
    of "((room $_) (here $who) $_)": keep(room, bl"(here $who $by)", by)
    of "((room $_) (from $r) $_)":
      if r.kind == bNum and r.num.isInt:
        for i in max(0, r.num.toInt) ..< told.len:
          if told[i][0] == room: a.say(by, told[i][1])
        let last = told.high
        a.say(by, bl"(through $room $last)")
    of "((room lobby) (open $name) $_)": asyncCheck hold(name)
    else: echo "passed over ", v

if fileExists(log):
  for rec in valuesIn(log):
    matchValue rec:
    of "(kept $room $_ $msg $_)": remember(room, msg, rec)
    else: discard
asyncCheck hold(lobby)
for (room, rec) in told:
  matchValue rec:
  of "(kept lobby $_ (opened $name) $_)": asyncCheck hold(name)
  else: discard
for i in 3 .. paramCount(): asyncCheck hold(sym(paramStr(i)))
runForever()
