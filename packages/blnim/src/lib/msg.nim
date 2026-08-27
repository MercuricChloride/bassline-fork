import pkg/core

type
  Send* = proc(m: Msg): bool
  ##[
  A send is a procedure that accepts a message.
  
  The return value of a send is whether the
  message was understood enough to be processed.

  It does NOT mean that it was totally understood
  or correct etc.
  ]##

  Msg* = ref object
    ##[
    A message is a dynamic location and
    can be replied to using msg.reply(aMsg)

    Messages with gas support a limited number
    of replies. This can be checked with
    msg.gasLeft, and messages with gas < 0
    support unbounded replies.
    ]##
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
  value: Value; onReply: Send = nil; gas = defaultGas): Msg =
  doAssert(
    gas != 0,
    "gas cannot be 0 initially. Use -1 for unbounded messages")
  Msg(value: value, onReply: onReply, gas: gas)

func gasLeft*(msg: Msg): int =
  msg.gas

func bounded*(msg: Msg): bool =
  ##[
  Whether or not msg has a bound on how
  many replies it can support
  ]##
  msg.gas >= 0

func exhausted*(msg: Msg): bool =
  msg.gas == 0

proc reply*(msg, res: Msg): bool {.discardable.} =
  if msg.exhausted: return
  if msg.gas > 0:
    dec msg.gas

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