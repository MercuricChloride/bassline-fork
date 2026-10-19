## The scene of examples/parties/basics.nim, at whatever party it is
## pointed at, written down instead of printed. `scene HOST PORT` prints
## it. It knows nothing of topics hosted inside others.

import std/[os, strutils]
import bl/core
import bl/parties/parties

const Step = 60  ## ms between steps

type Scene = ref object
  at: IpAddress
  port: Port
  lines*: seq[string]
  called: seq[(Value, string)]  # what each goes by, to write who said what

proc who(sc: Scene, name: Value): string =
  if name.kind == bNil: return "the party"
  for (v, s) in sc.called:
    if v == name: return s
  "someone"

proc shown(sc: Scene, v: Value): string =
  matchValue v:
  of "(name $s)": "(name " & sc.who(s) & ")"
  of "(alive $s)": "(alive " & sc.who(s) & ")"
  of "(dead $s)": "(dead " & sc.who(s) & ")"
  else: $v

proc listen(sc: Scene, a: Attendee) {.async.} =
  let me = sc.who(a.name)
  a.each msg:
    let topic = if msg.topic == a.name: "what " & me & " goes by" else: $msg.topic
    sc.lines.add $msg.n & " " & me & " heard " & sc.who(msg.by) & " say " &
      sc.shown(msg.value) & " into " & topic

proc attending(sc: Scene, name: string, owns: seq[Value] = @[]): Future[Attendee] {.async.} =
  let a = attend(sc.at, sc.port, owns)
  await a.ready
  sc.called.add (a.name, name)
  asyncCheck sc.listen(a)
  return a

proc step(sc: Scene, what: string) {.async.} =
  await sleepAsync(Step)
  sc.lines.add "-- " & what

proc scene*(at: IpAddress, port: Port): Future[seq[string]] {.async.} =
  let sc = Scene(at: at, port: port)
  let
    ann = await sc.attending("ann")
    bob = await sc.attending("bob")
    carl = await sc.attending("carl")
    dave = await sc.attending("dave", @[bl"(desk)"])
  await sc.step "ann hears status"
  ann.sub bl"status"
  await sc.step "bob and carl hear (kitchen), and ann says dinner is ready there"
  bob.sub bl"(kitchen)"
  carl.sub bl"(kitchen)"
  await sleepAsync(Step)
  ann.say bl"(kitchen)", bl"""(dinner "is ready")"""
  await sc.step "bob answers ann by saying into what she goes by"
  bob.say ann.name, bl"!(coming)"
  await sc.step "carl says something outside the dialect, and then into status"
  carl.send bl"(shout hi)"
  carl.say bl"status", bl"(alive nobody)"
  await sc.step "dave owns (desk). ann says there, then dave does, and bob hears (desk)"
  bob.sub bl"(desk)"
  await sleepAsync(Step)
  ann.say bl"(desk)", bl"(is anyone in)"
  await sleepAsync(Step)
  dave.say bl"(desk)", bl"(open until five)"
  await sc.step "erin asks to own (desk) too"
  let erin = await sc.attending("erin", @[bl"(desk)"])
  await sleepAsync(Step)
  erin.close
  await sc.step "carl stops hearing (kitchen), and ann calls again"
  carl.unsub bl"(kitchen)"
  await sleepAsync(Step)
  ann.say bl"(kitchen)", bl"(last call)"
  await sc.step "bob leaves, and ann says into what he went by"
  let went = bob.name
  bob.close
  await sleepAsync(Step)
  ann.say went, bl"(where are you)"
  await sleepAsync(Step)
  for a in [ann, carl, dave]: a.close
  return sc.lines

when isMainModule:
  if paramCount() < 2: quit "scene HOST PORT"
  for line in waitFor scene(parseIpAddress(paramStr(1)), Port(paramStr(2).parseInt)):
    echo line
