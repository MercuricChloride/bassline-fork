## One ledger, as one room: `sealed` in front of the rules over coins.
##
## The genesis gives ann 50 and bob 30. Ann pays bob 20 and keeps 30.
## Then come the ways to break the rules: ann spending the same coin
## again, mal spending bob's coin, a spend whose signature is of another
## transaction, ann making more than she spends. Each is told why to
## its speaker, and nobody else hears it.
##
## The wallet only works out who holds what from the spends it hears,
## trusting the room. The racer says its own spend the moment it hears
## anything: ann pays her 30 to bob, and the racer says ann's 30 to
## carol while the room is still passing her spend on. The room kept
## what it took before saying it, so the racer is refused, and the
## wallet never hears it.

import ./ledger

type
  Person = ref object of Participant
    name: string

  Wallet = ref object of Participant
    coins: Coins

  Racer = ref object of Participant
    spend: Value  ## what it says, once

method send(p: Person, msg: Msg) =
  if msg.value.isKind(bRec) and msg.value.head == bl"refused":
    echo "    ", p.name, " is told ", msg.value.brief

method send(w: Wallet, msg: Msg) =
  if msg.value.isSpend: w.coins.apply msg.value[1]

method send(r: Racer, msg: Msg) =
  if msg.value.isKind(bRec) and msg.value.head == bl"refused":
    echo "    the racer is told ", msg.value.brief
  if r.spend.isKind(bNil): return
  let s = r.spend
  r.spend = Value()
  echo "    the racer hears it and says ", s.brief
  echo "    taken: ", r.say(msg.room, s)

proc says(p: Person, room: Conversation, v: Value) =
  echo "  ", p.name, " says ", v.brief
  echo "    taken: ", p.say(room, v)

let
  (ann, bob, carol, mal) = (person"ann", person"bob", person"carol", person"mal")
  first = [ann.coinFor(50), bob.coinFor(30)]
  genesis = bl"(tx [] $first)"
  room = newLedger(genesis)
  wallet = Wallet(coins: newCoins(genesis))
  racer = Racer()
  (annP, malP) = (Person(name: "ann"), Person(name: "mal"))
  (annCoin, bobCoin) = (genesis.atOf(0), genesis.atOf(1))

annP.join room
malP.join room
wallet.join room

echo "ann pays bob 20 and keeps 30"
let paid = ann.pays([annCoin], [bob.coinFor(20), ann.coinFor(30)])
annP.says(room, paid)

echo "the rules"
annP.says(room, ann.pays([annCoin], [carol.coinFor(50)]))
malP.says(room, mal.pays([bobCoin], [mal.coinFor(30)]))
let forged = block:
  let (body, sig) = (mal.pays([bobCoin], [mal.coinFor(30)])[1],
                     bob.pays([bobCoin], [carol.coinFor(30)])[2])
  bl"(signed $body $sig)"
malP.says(room, forged)
annP.says(room, ann.pays([paid.atOf(1)], [carol.coinFor(40)]))
annP.says(room, bl"(hello)")

echo "the racer joins, and ann pays her 30 to bob"
racer.join room
racer.spend = ann.pays([paid.atOf(1)], [carol.coinFor(30)])
annP.says(room, ann.pays([paid.atOf(1)], [bob.coinFor(30)]))
echo "the wallet works out ", wallet.coins.held.toValue.brief
