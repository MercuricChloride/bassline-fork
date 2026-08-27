import pkg/core

type
  Send* = proc(m: Msg): bool
  ## A send is a procedure that accepts a message
  ## Returning whether the message was understood
  ## enough to be processed
  Msg* = ref object
    ## A message is a dynamic location
    value*: Value
    onReply: Send
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

proc reply*(msg, res: Msg): bool {.discardable.} =
  if msg.gas == 0: return
  elif msg.gas > 0: dec msg.gas

  if msg.onReply != nil:
    msg.onReply(res)
  else:
    defaultMsgSend(res)

proc reply*(msg: Msg, value: Value, onReply: Send = nil): bool {.discardable.} =
  msg.reply(newMsg(value, onReply))

proc send*(s: Send; value: Value; onReply: Send = nil): bool {.discardable.} =
  s(newMsg(value, onReply))

template logger*(s): Send =
  proc(msg: Msg): bool =
    echo s, msg.value

proc disableLogging*() =
  defaultMsgSend = voidSend
  defaultRoute = voidSend

proc enableLogging*() =
  defaultMsgSend = logger "defaultMsgSend: "
  defaultRoute = logger "defaultRoute: "