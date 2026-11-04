import std/[asyncdispatch, asyncnet]
import tinybl
import tinybl/net

useValue Val

type
  Msg* = object
    value*: Val
    src*: Target[Val]
    jam*: Jam

  Jam* = object
    toStamp*: Emitter[Val]
    ordered*: Source[Val]
    custom*: Emitter[Msg]

proc initMsg*(jam: Jam, value: Val, src: Target[Val]): Msg =
  Msg(jam: jam, value: value, src: src)

proc doStamp*(incoming: Listener[Val], ordered: Target[Val]) {.async.} =
  var height: int
  incoming.onEvent v:
    if not ordered.emit bl"(stamped $height $v)":
      incoming.close
    inc height

proc initJam*: Jam =
  let
    toStamp = newEmitter[Val](-1)
    ordered = newEmitter[Val](-1)
    custom = newEmitter[Msg](-1)
  asyncCheck doStamp(toStamp.listen, ordered.target)
  Jam(toStamp: toStamp, custom: custom, ordered: ordered.source)

proc close*(self: Jam) =
  self.toStamp.close
  self.ordered.close
  self.custom.close

proc join*(client: EventSocket[Val], jam: Jam) {.async.} =
  echo "client started"
  let toClient = client.outgoing.target
  client.incoming.listen.onEvent v:
    matchValue v:
    of "(put $msg)":
      if not jam.toStamp.emit(msg):
        client.close
    of "(get $msg)":
      let res = bl"(should-get $msg)"
      if not client.send(res):
        client.close
    else:
      if not jam.custom.emit(jam.initMsg(v, toClient)):
        client.close
  client.close
  echo "client disconnected"

proc serve*(jam: Jam, server: AsyncSocket) {.async.} =
  echo "serving"
  while true:
    let 
      sock = await server.accept()
      client = wrapSocket[Val](sock)
    asyncCheck jam.ordered.listen.dump(client.outgoing.target)
    asyncCheck client.join(jam)
  echo "done serving"

when isMainModule:

  proc myHandler(incoming: Listener[Msg]) {.async.} =
    incoming.onEvent msg:
      msg.src.emit bl"(idk $msg.value)"

  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(12345))
  server.listen()
  let jam = initJam()
  asyncCheck myHandler(jam.custom.listen)
  asyncCheck jam.serve(server)
  runForever()