## Rules for a moderated jam, each a proc deciding one message. None
## knows the others: they are put together with `all` and `first`, and
## with the jam's own rule, `answers()`.

import std/sugar
import ./common

export common

proc allow*(names: BSet): Rule =
  ## only those named in the set `names` are taken
  (c: Conversation, msg: Msg) =>
    msg.by in names or c.refusing(msg, bl"(not-allowed)")

proc cap*(n: int): Rule =
  ## nothing longer than `n` bytes of CE
  (c: Conversation, msg: Msg) =>
    msg.value.ce.len <= n or c.refusing(msg, bl"(too-big)")

proc muted*(names: BSet): Rule =
  ## nothing from someone in `names`
  (c: Conversation, msg: Msg) =>
    msg.by notin names or c.refusing(msg, bl"(muted)")

proc mute*(moderator: Value, names: BSet): Rule =
  ## !(mute NAME) from `moderator` puts NAME in `names`, and nobody hears it
  result = proc(c: Conversation, msg: Msg): bool =
    let v = msg.value
    if not (v.isKind(bRec, marked) and v.len == 2 and v.head == bl"mute"):
      return false
    if msg.by != moderator: return c.refusing(msg, bl"(not-the-moderator)")
    let who = v[1]
    c.keep: names.incl who
    true
