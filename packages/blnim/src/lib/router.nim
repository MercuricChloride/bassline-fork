import pkg/core

type
  Send* = proc(m: Msg): bool
  ## A send is a procedure that accepts a message
  ## It returns indicating whether the message
  ## was understood
  Msg* = ref object
    ## A message is a dynamic location
    value*: Value
    onReply*: Send
    gas: int

proc voidSend(msg: Msg): bool = discard

var
  defaultMsgSend*: Send = voidSend
  defaultRoute*: Send = voidSend
  defaultGas* = 1

# ================ Messages ================

func newMsg*(
  value: Value; 
  onReply: Send = nil; 
  gas = defaultGas): Msg =
  Msg(value: value, onReply: onReply, gas: gas)

func gasLeft*(msg: Msg): int =
  msg.gas

proc spend*(msg: Msg, n = 1) =
  if msg.gas > 0:
    dec msg.gas, n

proc reply*(msg, res: Msg): bool {.discardable.} =
  if msg.gas == 0: return
  if msg.gas > 0: msg.spend 1

  if msg.onReply != nil:
    msg.onReply(res)
  else:
    defaultMsgSend(res)

proc reply*(msg: Msg, value: Value, onReply: Send = nil): bool {.discardable.} =
  msg.reply(newMsg(value, onReply))

proc send*(s: Send; value: Value; onReply: Send = nil): bool {.discardable.} =
  s(newMsg(value, onReply))

# ================ Router templates ================

template route*(body: untyped) {.dirty.} =
  block currentRoute:
    if msg.gasLeft == 0: return
    body
    return

template next*() =
  break currentRoute

template accept*(cond) =
  result = cond
  if not result: next

template accept*(cond, body) =
  route:
    accept(cond)
    body

template ignore*(cond) =
  accept(not cond)

template router*(name, body: untyped) =
  proc name(m: Msg): bool {.discardable.} =
    var msg {.inject.}: Msg  = m
    body
    result = defaultRoute(msg)

template router*(body: untyped): Send =
  proc(m: Msg): bool {.discardable.} =
    var msg {.inject.}: Msg  = m
    body
    result = defaultRoute(msg)

# ================ Hooks ================

template logger*(s): Send =
  proc(msg: Msg): bool =
    echo s, msg.value

proc disableLogging*() =
  defaultMsgSend = voidSend
  defaultRoute = voidSend

proc enableLogging*() =
  defaultMsgSend = logger "defaultMsgSend: "
  defaultRoute = logger "defaultRoute: "

when isMainModule:
  template ping: Value = sym"ping"
  template pong: Value = sym"pong"

  router foo:

    accept msg.value == ping:
      msg.reply pong

    accept msg.value == pong:
      msg.reply sym"what"

  proc main() =
    var count: int
    while count < 100_000:
      inc count
      if count mod 100 == 0:
        echo count
      foo.send ping
      foo.send pong

  main()