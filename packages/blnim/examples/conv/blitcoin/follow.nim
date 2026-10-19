## What follows from what is heard in a chain, worked out by each
## participant for itself.
##
## A `Follower` keeps every block it hears and works out which branch
## is best: the one whose blocks show the most work, the first heard
## among equals. Everyone in one chain hears its blocks in one order,
## so everyone in it works out the same branch.
##
## A `Wallet` works out who holds what on the best branch. A `Miner`
## also keeps the spends it hears, in its pool, and asked to mine it
## makes a block on the best branch of those spends a fresh ledger
## takes after that branch, and says it into the chain. A `Carrier` is
## in two conversations and says into each, a moment later, the blocks
## and spends it hears in the other.

import ./chain
export chain

type
  Follower* = ref object of Participant
    blocks*: BDict
    work: BTree[Value, int]  ## the work behind each block, its own counted
    heard: seq[Value]        ## ids, in the order heard

  Wallet* = ref object of Follower

  Miner* = ref object of Follower
    ledger*: Ledgers
    pool: seq[Value]  ## spends heard, in the order heard

  Carrier* = ref object of Inbox

proc init*[T: Follower](f: T): T =
  f.blocks = newBDict()
  f.work = newBTree[Value, int]()
  f

method send*(f: Follower, msg: Msg) =
  let v = msg.value
  if not (v.isKind(bRec) and v.head == bl"block"): return
  let id = v.idOf
  if id in f.blocks: return
  f.blocks[id] = v
  f.work[id] = v.work + (if v[1].isKind(bNil): 0 else: f.work[v[1]])
  f.heard.add id

proc best*(f: Follower): Value =
  ## the id of the first block heard among those with the most work
  var most = -1
  for id in f.heard:
    if f.work[id] > most: (most, result) = (f.work[id], id)

proc height*(f: Follower): int = f.blocks.branch(f.best).len - 1

proc mostWork*(f: Follower): int = f.work[f.best]

proc holds*(w: Wallet): Value =
  ## who holds what on the best branch
  let branch = w.blocks.branch(w.best)
  let coins = newCoins(branch[0][3][0])
  for b in branch[1 .. ^1]:
    for spend in b[3].items: coins.apply spend[1]
  coins.held.toValue

proc pending*(m: Miner): seq[Value] = m.pool

method send*(m: Miner, msg: Msg) =
  procCall Follower(m).send(msg)
  if msg.value.isSpend and msg.value notin m.pool: m.pool.add msg.value

proc mine*(m: Miner, chain: Room, bits = MinBits): Value =
  ## a block on the best branch of the spends a ledger takes after it,
  ## said into `chain`. Each is its own decision, so the ledger judges
  ## each against those it took before
  let ledger = m.ledger(m.blocks.spendsOn(m.best))
  var spends: seq[Value]
  for spend in m.pool:
    if ledger.takes(spend): spends.add spend
  result = grind(m.best, bits, spends)
  discard m.say(chain, result)

proc carry*(c: Carrier) {.async.} =
  c.each msg:
    let v = msg.value
    if v.isKind(bRec) and v.head in [bl"block", bl"signed"]:
      c.say(v, but = msg.room)
