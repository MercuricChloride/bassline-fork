## Two peers, each a pool and a chain of its own, and a carrier between
## each pair, carrying a moment later, as a wire would.
##
## A pool takes any signed spend once, two spends of one coin alike,
## since which coins are unspent depends on the branch. A chain takes
## valid blocks on every branch, and each peer's wallet and miner work
## out the best branch for themselves, by work. A miner takes, in the
## order it heard them, the spends a ledger takes after its best branch.
##
## Ann spends her 50 to bob at p1 and to carol at p2 at once. Both
## spends reach both pools, each miner takes the one it heard first,
## and both mine at once. Each block crosses, and each peer holds both,
## equal in work, each on the branch it heard first. A second
## block on p2's branch is more work, and once it crosses both peers
## are on it: carol holds the 50, and p1's miner leaves ann's spend to
## bob out of its next block, since the best branch spent that coin.
##
## Then the peers part, and carol spends her 50 to dave at p1 and to
## erin at p2. p1 mines two blocks, p2 one with more work than both.
## When the carrier joins both chains again, each tells it every block
## it holds, and both peers go to p2's shorter branch.

import ./[ledger, follow]
export ledger, follow

type
  Peer* = object
    name*: string
    pool*, chain*: Conversation
    miner*: Miner
    wallet*: Wallet

  LoudCarrier* = ref object of Carrier
    ## a carrier that says when it is refused, but for blocks held already

var names: seq[(Room, string)]  # for printing only

proc named*(c: Conversation, name: string): Conversation =
  names.add (c.room, name)
  c

proc called*(r: Room): string =
  for (each, name) in names:
    if each == r: return name

method send(c: LoudCarrier, msg: Msg) =
  let v = msg.value
  if v.isKind(bRec) and v.head == bl"refused" and v[1].isKind(bRec) and
      v[1].head != bl"held":
    echo "    the carrier is told ", v.brief, " in ", msg.room.called
  procCall Carrier(c).send(msg)

let
  (ann*, bob*, carol*, dave*, erin*) =
    (person"ann", person"bob", person"carol", person"dave", person"erin")
  first = [ann.coinFor(50)]
  genesis* = bl"(tx [] $first)"
  fresh: Ledgers = proc(spends: seq[Value]): Conversation = newLedger(genesis, spends)
  someone = Participant()  # joins whatever it says into

proc peer*(name: string): Peer =
  result = Peer(name: name, pool: newPool().named(name & "'s pool"),
                chain: newChain(genesis, fresh).named(name & "'s chain"),
                miner: Miner(ledger: fresh).init, wallet: Wallet().init)
  result.miner.join result.pool
  result.miner.join result.chain
  result.wallet.join result.chain

proc bridge*(a, b: Room): Carrier =
  result = LoudCarrier()
  result.join a
  result.join b
  asyncCheck result.carry

proc show*(p: Peer) =
  let w = p.wallet
  echo "  ", p.name, " holds ", w.blocks.len, " blocks, best ", w.best.brief,
    " at height ", w.height, " with work ", w.mostWork, ": ", w.holds.brief

proc says*(c: Conversation, v: Value) =
  someone.join c
  echo "  ", v.brief, " said into ", c.room.called, ", taken: ", someone.say(c, v)

proc making(spends: openArray[Value]): Value =
  ## the coins the spends make, for printing
  var made: seq[Value]
  for spend in spends:
    for each in spend[1][2].items: made.add each.brief
  toValue(made)

proc mines*(p: Peer, bits = MinBits) =
  let b = p.miner.mine(p.chain, bits)
  echo "  ", p.name, " mines ", b.idOf.brief, " on ", b[1].brief, " with ",
    bits, " bits, making ", b[3].items.data.making

proc heard*(p: Peer) =
  echo "  ", p.name, "'s miner heard spends making ", p.miner.pending.making

proc main() {.async.} =
  let (p1, p2) = (peer"p1", peer"p2")
  let (pools, chains) = (bridge(p1.pool, p2.pool), bridge(p1.chain, p2.chain))
  let (toBob, toCarol) = (ann.pays([genesis.atOf(0)], [bob.coinFor(50)]),
                          ann.pays([genesis.atOf(0)], [carol.coinFor(50)]))

  echo "ann spends her 50 twice at once"
  p1.pool.says toBob
  p2.pool.says toCarol
  await sleepAsync(10)
  p1.heard
  p2.heard

  echo "each miner mines at once"
  p1.mines
  p2.mines
  p1.show
  p2.show
  await sleepAsync(10)
  echo "the blocks cross"
  p1.show
  p2.show

  echo "p2 mines again"
  p2.mines
  await sleepAsync(10)
  p1.show
  p2.show
  echo "p1 mines next"
  p1.mines
  await sleepAsync(10)

  echo "the peers part, and carol spends her 50 twice"
  for c in [pools, chains]: c.leaveAll
  let carolCoin = toCarol.atOf(0)
  p1.pool.says carol.pays([carolCoin], [dave.coinFor(50)])
  p2.pool.says carol.pays([carolCoin], [erin.coinFor(50)])
  p1.mines
  p1.mines
  p2.mines(bits = 11)
  p1.show
  p2.show

  echo "the carrier joins both chains again"
  chains.join p1.chain
  chains.join p2.chain
  await sleepAsync(20)
  p1.show
  p2.show

when isMainModule: waitFor main()
