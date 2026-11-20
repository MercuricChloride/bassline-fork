## The double spend of peers.nim with p2 across TCP. p2's pool and
## chain each listen on a port, and the listener joins a wire to each
## for every connection. p1 reaches each through a link, a plain
## conversation holding a dialled wire and a carrier that is also in
## p1's pool or chain.
##
## Nothing in a pool, a chain, a ledger or a follower asks who said a
## value, only what it carries, a signature or work, so none of it
## changes. What p2 tells the wire alone, a refusal, reaches p1 said
## into the link by the wire there, so everyone in the link hears it.

import ./peers
import bl/conv/tcp

proc reach(near, far: Room, name: string): Future[Conversation] {.async.} =
  ## `far` listened on, and a link dialled to it, with a carrier in the
  ## link and in `near`
  let
    served = listen(Port(0), far, "127.0.0.1")
    link = Conversation().named(name)
    carrier = LoudCarrier()
  discard await dial("127.0.0.1", served.port, link)
  carrier.join link
  carrier.join near
  asyncCheck carrier.carry
  return link

proc main() {.async.} =
  let (p1, p2) = (peer"p1", peer"p2")
  discard await reach(p1.pool, p2.pool, "the pool link")
  let chainLink = await reach(p1.chain, p2.chain, "the chain link")
  await sleepAsync(50)
  let (toBob, toCarol) = (ann.pays([genesis.atOf(0)], [bob.coinFor(50)]),
                          ann.pays([genesis.atOf(0)], [carol.coinFor(50)]))

  echo "ann spends her 50 twice at once"
  p1.pool.says toBob
  p2.pool.says toCarol
  await sleepAsync(50)
  p1.heard
  p2.heard

  echo "each miner mines at once"
  p1.mines
  p2.mines
  await sleepAsync(50)
  p1.show
  p2.show

  echo "p2 mines again"
  p2.mines
  await sleepAsync(50)
  p1.show
  p2.show

  echo "a block spending a coin nobody made, said into the chain link"
  let bogus = carol.pays([genesis.atOf(7)], [carol.coinFor(5)])
  chainLink.says grind(p1.wallet.best, MinBits, [bogus])
  await sleepAsync(50)

waitFor main()
