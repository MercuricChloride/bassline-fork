import std/[async, tables, sequtils]
import ../[core, ops]
import ../lib/blmacro
import ./[msg, router]

type
  OnFail* = proc(e: ref Exception) {.gcsafe.}
  AsyncSend* = proc(m: Msg): Future[void]
  TaskPool* = ref object
    ## Provides a future pool for custody of futures a synchronous `Send`
    ## starts. Futures tracked with this will route to `onFail` upon failure.
    live: Table[uint, Future[void]]
    nextId: uint
    onFail: OnFail
    open = true

proc newTaskPool*(onFail: OnFail = nil): TaskPool =
  TaskPool(onFail: onFail)

proc track*(self: TaskPool, fut: Future[void]) =
  if not self.open:
    fut.addCallback(proc(f: Future[void]) =
      if f.failed and self.onFail != nil: self.onFail(f.readError))
    return
  let id = self.nextId
  inc self.nextId
  self.live[id] = fut
  fut.addCallback proc(f: Future[void]) =
    self.live.del id
    if f.failed and self.onFail != nil:
      self.onFail(f.readError)

proc bridge*(self: TaskPool, s: AsyncSend): Send =
  ## `s` as a synchronous `Send`
  proc(m: Msg): bool =
    if not self.open: return false
    try:
      self.track s(m)
      true
    except CatchableError as e:
      if self.onFail != nil: self.onFail(e)
      false

proc drain*(self: TaskPool) {.async.} =
  ## Awaits everything in flight then refuses new tasks.
  if not self.open: return
  self.open = false
  for f in toSeq(self.live.values):
    try: await f
    except CatchableError: discard

# ================ Pub / Sub ================

type
  PubSub* = ref object
    ## A token -> messages table. No addresses: a token is any value the
    ## subscriber picked, and a published value carries the tokens it
    ## should be seen under as data.
    subs: Table[Value, seq[Msg]]

proc newPubSub*(): PubSub = PubSub()

proc sub*(self: PubSub; msg: Msg; tokens: openArray[Value]) =
  ## `msg` is subscribed under each token. A later `pub` whose value one
  ## of these tokens prefixes delivers to `msg`.
  for t in tokens:
    self.subs.mgetOrPut(t, @[]).add msg

proc pub*(self: PubSub; v: Value; tokens: openArray[Value]): int {.discardable.} =
  ## Deliver `v` (with no reply path) to every message whose token
  ## prefixes one of `tokens`. A subscriber that is exhausted, or whose
  ## reply path has gone (a closed connection answers `false`), is
  ## reaped from every touched token; a token left with none is dropped.
  ## Returns how many messages `v` reached.
  var
    delivered: seq[Msg]
    dead: seq[Msg]
  for st in toSeq(self.subs.keys):
    if not tokens.anyIt(prefixes(st, it)): continue
    var live: seq[Msg]
    for m in self.subs[st]:
      if m.exhausted or m in dead: continue
      if m notin delivered:
        delivered.add m
        if m.reply(v): inc result
        else: dead.add m
      if m notin dead and not m.exhausted: live.add m
    if live.len == 0: self.subs.del st
    else: self.subs[st] = live

proc pub*(self: PubSub; v: Value): int {.discardable.} =
  ## `v` routes by itself: to every subscriber whose token prefixes it.
  self.pub(v, [v])

proc newSend*(self: PubSub): Send =
  ## The wire forms. `!sub({toks})` subscribes this message under each
  ## token; `!pub(v {toks})` delivers `v` to whoever is subscribed under
  ## a token that prefixes one of `toks`.
  router:
    accept bl(!sub()).prefixes msg.value:
      accept msg.value.items.len == 2
      let toks = msg.value.items[1]
      accept toks.kind == bSet
      self.sub(msg, toSeq(toks.els))

    accept bl(!pub()).prefixes msg.value:
      accept msg.value.items.len == 3
      let
        v = msg.value.items[1]
        toks = msg.value.items[2]
      accept toks.kind == bSet
      self.pub(v, toSeq(toks.els))