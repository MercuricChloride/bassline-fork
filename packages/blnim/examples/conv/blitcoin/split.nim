## The ledger's rules pulled apart into two halves that each keep their
## own state: `spent`, which keeps which coins were spent and refuses a
## coin spent already, and `made`, which keeps which coins were made,
## judges the other three rules and passes on what it takes. Each is
## small, and each holds only what it needs.
##
## Either half can stand in front of the other. What either keeps for a
## spend is kept only once both have taken it, and before anything is
## passed on, and nothing is kept for a spend either refuses.
##
## So whoever hears a spend while it is being passed on, and speaks at
## once, is judged against both halves having kept it. The racer says
## ann's coin to carol while ann's spend of it to bob is being passed
## on, and is refused.
##
## And a half that refuses undoes what the other kept and said for the
## spend. With `spent` in front, it keeps ann's coin as spent before
## `made` refuses her spend for making more than it spends, and her
## honest spend of the same coin is taken all the same. With `made` in
## front, it passes on a spend of a coin spent already before `spent`
## refuses it, and nobody hears it.
##
## Everything comes out the same with either half in front.

import ./ledger

type
  Watcher = ref object of Participant
    coins: Coins

  Racer = ref object of Participant
    spend: Value

  Person = ref object of Participant  ## says aloud why it was refused

var
  lines: seq[string]  # everything shown, to compare the two orders
  quiet = false

proc show(line: string) =
  lines.add line
  if not quiet: echo line

proc isRefusal(v: Value): bool = v.isKind(bRec) and v.head == bl"refused"

method send(w: Watcher, msg: Msg) =
  if msg.value.isSpend:
    show "    the watcher hears " & $msg.value.brief
    w.coins.apply msg.value[1]

method send(p: Person, msg: Msg) =
  if msg.value.isRefusal: show "    ann is told " & $msg.value.brief

method send(r: Racer, msg: Msg) =
  if msg.value.isRefusal: show "    the racer is told " & $msg.value.brief
  if r.spend.isKind(bNil) or not msg.value.isSpend: return
  let s = r.spend
  r.spend = Value()
  let taken = r.say(msg.room, s)
  show "    the racer says " & $s.brief & ", taken: " & $taken

let
  (ann, bob, carol) = (person"ann", person"bob", person"carol")
  first = [ann.coinFor(50)]
  genesis = bl"(tx [] $first)"
  annCoin = genesis.atOf(0)
  annP = Person()

proc halves(spentFirst: bool): (Conversation, Watcher) =
  let
    k = newCoins(genesis)
    spent = all(unspent(k.spent), spending(k.spent))
    made = all(known(k.made), theirs(k.made), covered(k.made), making(k.made),
               asSaid(toSpeaker = true))
    room = Conversation(rule:
      if spentFirst: all(sealed(), spent, made) else: all(sealed(), made, spent))
    watcher = Watcher(coins: newCoins(genesis))
  watcher.join room
  annP.join room
  (room, watcher)

proc says(c: Conversation, v: Value) =
  show "  ann says " & $v.brief
  let taken = annP.say(c, v)
  show "    taken: " & $taken

proc run(spentFirst: bool): seq[string] =
  lines = @[]
  show "nobody racing"
  var (c, watcher) = halves(spentFirst)
  c.says ann.pays([annCoin], [bob.coinFor(50)])
  c.says ann.pays([annCoin], [carol.coinFor(50)])

  show "with the racer in the room"
  (c, watcher) = halves(spentFirst)
  Racer(spend: ann.pays([annCoin], [carol.coinFor(50)])).join c
  c.says ann.pays([annCoin], [bob.coinFor(50)])
  show "  the watcher works out " & $watcher.coins.held.toValue.brief

  show "made refuses a spend, then comes the honest one"
  (c, watcher) = halves(spentFirst)
  c.says ann.pays([annCoin], [bob.coinFor(60)])
  c.says ann.pays([annCoin], [bob.coinFor(50)])
  lines

echo "spent in front of made"
let inFront = run(spentFirst = true)
quiet = true
echo "made in front of spent, the same: ", run(spentFirst = false) == inFront
