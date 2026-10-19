##[
  chat: someone in a jam's rooms, through the keeper that owns them at a
  party on [::1]. It does what its arguments say, in turn, and prints
  what it hears:

    chat PORT NAME STEP …

    (join ROOM)       hears (room ROOM), says (here NAME) there and asks
                      for what it hasn't heard, (from R)
    (post ROOM TEXT)  says (post (says NAME TEXT AT)) there, and again
                      every half second until it hears it kept
    (open ROOM)       says (open ROOM) into the lobby, and waits until it
                      hears the room opened
    (wait MS)         waits

  On each connection after its first it says it is here again in every
  room it joined, and asks for what it missed. It leaves when its steps
  are done.
]##
import std/[os, sequtils, strutils, tables, times]
import bl/core
import bl/parties/parties

blet"{lobby}"

let
  a = attend(parseIpAddress("::1"), Port(paramStr(1).parseInt))
  name = sym(paramStr(2))
var
  joined: seq[Value]            # the rooms it hears
  heard = newBSet()             # every (ROOM MSG) it has heard kept
  last: Table[Value, int]       # the highest rank heard in each room
  pending: seq[(Value, Value)]  # (ROOM MSG) posted and not yet heard kept
  connections = 0

proc show(s: string) = echo name.text, "  ", s

proc shown(msg: Value): string =
  matchValue msg:
  of "(says $who $text $_)": $who & ": " & $text
  else: $msg

proc greet(room: Value) =
  let r = last.getOrDefault(room, -1) + 1
  a.say(bl"(room $room)", bl"(here $name)")
  a.say(bl"(room $room)", bl"(from $r)")

proc hearing() {.async.} =
  a.each said:
    let (t, v) = (said.topic, said.value)
    matchValue bl"($t $v)":
    of "($_ (name $_))":
      inc connections
      if connections > 1: joined.apply greet
    of "($_ (kept $room $r $msg $_))":
      if bl"($room $msg)" notin heard:
        heard.incl bl"($room $msg)"
        last[room] = max(last.getOrDefault(room, -1), r.num.toInt)
        pending.keepItIf(it != (room, msg))
        show $room & " " & $r & "  " & msg.shown
    of "($_ (through $room $r))": show "caught up on " & $room & " through " & $r
    of "((room $room) (post $msg))": show "heard a post nobody kept in " & $room & ": " & msg.shown
    else: show "heard " & $v

proc resaying() {.async.} =
  while true:
    await sleepAsync(500)
    for (room, msg) in pending: discard a.say(bl"(room $room)", bl"(post $msg)")

proc join(room: Value) =
  if room in joined: return
  joined.add room
  a.sub bl"(room $room)"
  greet room

proc run() {.async.} =
  for i in 3 .. paramCount():
    let step = readValue(paramStr(i))
    matchValue step:
    of "(join $room)": join room
    of "(post $room $text)":
      let at = int(epochTime() * 1000)
      let msg = bl"(says $name $text $at)"
      pending.add (room, msg)
      a.say(bl"(room $room)", bl"(post $msg)")
    of "(open $room)":
      join lobby
      a.say(bl"(room lobby)", bl"(open $room)")
      while bl"(lobby (opened $room))" notin heard: await sleepAsync(20)
    of "(wait $ms)": await sleepAsync(ms.num.toInt)
    else: show "can't do " & $step

asyncCheck hearing()
asyncCheck resaying()
waitFor run()
a.close
