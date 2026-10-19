## A chain of blocks, as one conversation put together from rules.
##
## `worked` is a door that refuses what isn't a block showing the work
## it claims. It keeps nothing.
##
## A `Chain` keeps every block it takes, on every branch. It refuses a
## block it holds already, one whose PREV it doesn't hold, and one
## whose spends a ledger won't take after the branch before it. For
## that it makes a fresh ledger for each spend, holding what the branch
## and the block's spends before it spent and made, says the spend into
## it and listens for the answer, so it knows nothing of the rules for
## spends: they are whatever conversation `ledger` makes. Which branch
## is best it leaves to whoever hears. Every block it takes it says to
## everyone, the speaker too, in the order it took them, and it tells a
## newcomer every block it holds.
##
## A ledger is given what came before rather than told it. Whatever the
## chain says into a ledger while deciding is part of its decision, and
## a ledger's rules see only what it kept before the decision began, so
## each spend said into one ledger would be judged as if no other had
## been said.

import std/sequtils
import ./[blocks, door]
export blocks, door

type
  Ledgers* = proc(spends: seq[Value]): Conversation
    ## a fresh ledger holding the genesis coins and what `spends` spent
    ## and made, taken as they are

  Chain* = ref object of Conversation
    ledger*: Ledgers
    blocks*: BDict     ## every block taken, by id
    taken: seq[Value]  ## their ids, in the order taken

let voice = Participant()  # says spends into ledgers nobody else is in

proc takes*(ledger: Conversation, spend: Value): bool =
  voice.join ledger
  voice.say(ledger, spend)

proc spendsOn*(blocks: BDict, id: Value): seq[Value] =
  ## every spend on the branch to the block named id, oldest first
  for b in blocks.branch(id)[1 .. ^1]: result.add b[3].items.data

template overBlocks(judging: untyped): Rule =
  ## a chain's rule over blocks, with `chain`, `v`, `c` and `msg` bound.
  ## It takes anything else, which `worked` refuses
  proc(c {.inject.}: Conversation, msg {.inject.}: Msg): bool =
    let (chain {.inject.}, v {.inject.}) = (Chain(c), msg.value)
    if not v.isBlock: return true
    judging

proc worked*(): Rule =
  door proc(v: Value): Value =
    if not v.isBlock: bl"not-a-block"
    elif not v.showsWork: bl"no-work"
    else: Value()

proc unheld(): Rule = overBlocks:
  let id = v.idOf
  id notin chain.blocks or c.refusing(msg, bl"(held $id)")

proc follows(): Rule = overBlocks:
  let prev = v[1]
  prev in chain.blocks or c.refusing(msg, bl"(no-prev $prev)")

proc spendable(): Rule = overBlocks:
  if v[1] notin chain.blocks: return true
  var before = chain.blocks.spendsOn(v[1])
  for spend in v[3].items:
    if not chain.ledger(before).takes(spend):
      let tx = spend[1].idOf
      return c.refusing(msg, bl"(bad-spend $tx)")
    before.add spend
  true

proc keeping(): Rule = overBlocks:
  let id = v.idOf
  c.keep:
    chain.blocks[id] = v
    chain.taken.add id
  c.reflect(msg, toSpeaker = true)
  true

method joined*(c: Chain, name: Value) =
  c.tell(name, c.taken.mapIt(c.blocks[it]))

proc newChain*(genesis: Value, ledger: Ledgers): Conversation =
  let (first, id) = (genesis.firstBlock, genesis.firstBlock.idOf)
  let chain = Chain(ledger: ledger, blocks: newBDict(), taken: @[id],
                    rule: all(worked(), unheld(), follows(), spendable(), keeping()))
  chain.blocks[id] = first
  chain
