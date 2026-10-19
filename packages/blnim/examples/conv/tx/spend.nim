## Spend checking, after blitcoin, with keys as names. A spend is
## (signed (tx ID [(at ID N) …] [(coin KEY AMOUNT) …]) KEY): it spends
## the coins it names and makes new ones. Six rules each judge one thing
## and `book` keeps what a spend spends and makes, then passes it on.
## None knows the others, and every order of them takes the same spends.

import std/[algorithm, sequtils, strutils, sugar]
import ./common

type Coins = ref object
  made: BTree[Value, Value]  ## every coin, by its (at ID N)
  spent: BSet

proc txOf(v: Value): Value =
  ## the transaction a spend signs, or nil when `v` isn't one
  if v.isKind(bRec, unmarked) and v.len == 3 and v.head == bl"signed" and
      v[2].isKind(bSym) and v[1].isKind(bRec, unmarked) and v[1].len == 4 and
      v[1].head == bl"tx" and v[1][2].isKind(bList) and v[1][3].isKind(bList):
    result = v[1]

template spends(body: untyped): Rule =
  ## a rule over spends, with `tx`, `signer`, `c` and `msg` bound. It
  ## passes over anything else, which `sealed` refuses
  proc(c {.inject.}: Conversation, msg {.inject.}: Msg): bool =
    let tx {.inject.} = msg.value.txOf
    if tx.kind == bNil: return true
    let signer {.inject.} = msg.value[2]
    body

proc sealed(): Rule =
  (c: Conversation, msg: Msg) =>
    msg.value.txOf.kind != bNil or c.refusing(msg, bl"not-a-spend")

proc idFree(k: Coins): Rule = spends:
  let id = tx[1]
  bl"(at $id 0)" notin k.made or c.refusing(msg, bl"(id-taken $id)")

proc known(k: Coins): Rule = spends:
  for at in tx[2].items:
    if at notin k.made: return c.refusing(msg, bl"(no-such-coin $at)")
  true

proc unspent(k: Coins): Rule = spends:
  let seen = newBSet()
  for at in tx[2].items:
    if at in k.spent or at in seen: return c.refusing(msg, bl"(spent $at)")
    seen.incl at
  true

proc theirs(k: Coins): Rule = spends:
  for at in tx[2].items:
    if at in k.made and k.made[at][1] != signer:
      return c.refusing(msg, bl"(not-theirs $at)")
  true

proc covered(k: Coins): Rule = spends:
  var (ins, outs) = (0, 0)
  for at in tx[2].items:
    if at in k.made: ins += k.made[at][2].num.toInt
  for coin in tx[3].items: outs += coin[2].num.toInt
  outs <= ins or c.refusing(msg, bl"(uncovered $ins $outs)")

proc book(k: Coins): Rule = spends:
  let (ats, id, coins) = (tx[2].items.data, tx[1], tx[3].items.data)
  c.keep:
    for at in ats: k.spent.incl at
    for n, coin in coins: k.made[bl"(at $id $n)"] = coin
  c.reflect(msg, toSpeaker = false)
  true

proc pays(signer, id: string, spends, makes: openArray[Value]): Value =
  let (signer, id) = (sym(signer), sym(id))
  bl"(signed (tx $id $spends $makes) $signer)"

proc run(order: seq[string]): seq[string] =
  transcript = @[]
  let k = Coins(made: newBTree[Value, Value](), spent: newBSet())
  k.made[bl"(at g 0)"] = bl"(coin ann 50)"
  k.made[bl"(at g 1)"] = bl"(coin ann 30)"
  var rs = order.mapIt:
    case it
    of "sealed": sealed()
    of "idFree": idFree(k)
    of "known": known(k)
    of "unspent": unspent(k)
    of "theirs": theirs(k)
    else: covered(k)
  let ledger = room(all(rs & book(k)))
  let (ann, bob, racer) = (person"ann", person"bob", person"racer")
  racer.hears = proc(p: Person, msg: Msg) =
    if "bob 50" in $msg.value:  # as it hears ann pay bob, it spends the same coin
      p.says(msg.room, pays("ann", "t2", [bl"(at g 0)"], [bl"(coin racer 50)"]))
  for p in [ann, bob, racer]: p.join ledger
  ann.says(ledger, pays("ann", "t1", [bl"(at g 0)"], [bl"(coin bob 50)"]))
  ann.says(ledger, pays("ann", "t3", [bl"(at g 1)"], [bl"(coin bob 40)"]))
  ann.says(ledger, pays("ann", "t3", [bl"(at g 1)"], [bl"(coin bob 20)", bl"(coin ann 10)"]))
  bob.says(ledger, pays("bob", "t4", [bl"(at t3 1)"], [bl"(coin bob 10)"]))
  bob.says(ledger, pays("bob", "t4", [bl"(at t1 0)", bl"(at t1 0)"], [bl"(coin carol 100)"]))
  bob.says(ledger, pays("bob", "t5", [bl"(at t1 0)"], [bl"(coin carol 50)"]))
  bob.says(ledger, bl"(hello)")
  show "  unspent: " & $toSeq(k.made.pairs).filterIt(it.key notin k.spent).mapIt(it.val)
  transcript

discard run(@["sealed", "idFree", "known", "unspent", "theirs", "covered"])

quiet = true
var order = @["covered", "idFree", "known", "sealed", "theirs", "unspent"]
var (orders, seen, verdicts) = (0, newSeq[seq[string]](), newSeq[seq[string]]())
while true:
  let t = run(order)
  inc orders
  if t notin seen: seen.add t
  let v = t.filterIt("(refused" notin it)
  if v notin verdicts: verdicts.add v
  if not order.nextPermutation: break
echo "\n", orders, " orders: ", verdicts.len, " outcome, ", seen.len, " sets of reasons"
