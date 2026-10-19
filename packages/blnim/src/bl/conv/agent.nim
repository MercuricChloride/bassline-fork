import std/[macros, strutils]
import ../core
import ./conv

type
  Agent = ref object of Speaker
    body: proc(a: Agent, msg: Msg)

method send(self: Agent, msg: Msg) =
  if not isNil(self.body):
    self.body(self, msg)

proc newAgent*(body: Agent.body): Agent =
  Agent(body: body)

macro agent*(fn: untyped) =
  fn.expectKind(nnkProcDef)
  let fnName = fn[0]
  var name = fnName.strVal
  name[0] = name[0].toUpperAscii
  let newAgentName = ident("new" & name)
  quote do:
    `fn`
    proc `newAgentName`*(): Agent =
      newAgent(`fnName`)
    
    proc `newAgentName`*(room: Room): Agent =
      result = `newAgentName`()
      result.join(room)

proc logger(self: Agent, msg: Msg) {.agent.} =
  echo "logger received"

blet "{a: ping b: pong}"

proc pinger(self: Agent, msg: Msg) {.agent.} =
  echo "[pinger]: ", msg.value
  matchValue msg.value:
  of a:
    self.reply(msg, b)

proc ponger(self: Agent, msg: Msg) {.agent.} =
  echo "[ponger]: ", msg.value
  matchValue msg.value:
  of b:
    self.reply(msg, a)

let
  room = Conversation()
  foo = newPinger(room)
  bar = newPonger(room)

room.say(bl"foo")

room.say b