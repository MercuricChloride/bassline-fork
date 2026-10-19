import std/cmdline
import ../core
import ./[conv, stdio, tcp]

blet"{serve-tcp connect-tcp standard-io ping pong}"

type Logger* = ref object of Participant

method send*(self: Logger, msg: Msg) =
  echo msg.value
  if msg.value == ping:
    discard self.say(msg.room, pong)

proc handler(v: Value, room: Room) {.async.} =
  if not v.isKind({bRec}, marked): return
  let h = v.head
  if h == serveTcp and v.len == 2:
    try: 
      discard listen(Port(v[1].num.toInt), room)
      echo "started server"
    except: discard
  elif h == connectTcp and v.len == 3:
    try: 
      let p = await dial(v[1].text, Port(v[2].num.toInt), room)
      discard p.say(room, ping)
    except: discard
  elif h == standardIo:
    input.join(room)
    output.join(room)

proc main() {.async.} =
  let 
    args = commandLineParams()
    values = readDocument(readFile(args[0]))
    root = Conversation()
    log = Logger()
  log.join(root)

  for v in values: 
    await handler(v, root)

  await sleepAsync(1_000)

  await sleepAsync(10_000)

when isMainModule:
  let f = main()
  waitFor f