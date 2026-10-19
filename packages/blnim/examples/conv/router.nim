import bl/[core, conv]

type
  Router = ref object of Participant
    routes: BTree[Value, Room]
  Logger = ref object of Participant
    tag: Value

method send(l: Logger, msg: Msg) =
  echo l.tag, " ", msg.value

blet "{give}"

method send(s: Router, msg: Msg) =
  matchValue msg.value:
  of "!(send $dest $val)":
    s.say(s.routes[dest], val)

proc `[]=`(s: Router, key: Value, conv: Room) =
  s.routes[key] = conv
  s.join(conv)

proc `[]`*(s: Router, key: Value): Room =
  s.routes[key]

proc newRouter(routes: openArray[(Value, Conversation)]): Router =
  result = Router(routes: newBTree[Value, Room]())
  for (k, conv) in routes:
    result[k] = conv

blet "{ctl room}"

let
  common = Conversation()
  router = newRouter({ ctl: Conversation(), room: Conversation() })
  me = Participant()  # one that only speaks

Logger(tag: bl"common-log").join(common)
Logger(tag: bl"ctl-log").join(router[ctl])
Logger(tag: bl"room-log").join(router[room])

router.join(common)
me.join(common)

let script = bl"""[
  !(give something hello)
  !(give ctl hi-ctl)
  !(give room something!)
  hi
  foo
]"""

for each in script.items:
  discard me.say(common, each)