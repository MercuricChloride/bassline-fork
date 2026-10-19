## The ledger, as one conversation put together from rules.
##
## `sealed` is a door that refuses what isn't a spend whose signature
## holds. It keeps nothing, so it can stand in front of anything.
##
## Four rules judge a spend against the coins: `known` refuses one
## naming a coin never made, `unspent` one spent already, `theirs` one
## held by another key than the signer's, and `covered` one making more
## than it spends. `spending` and `making` keep what a spend spends and
## makes. Each holds only what it reads or keeps and passes over what
## isn't its business, as `theirs` passes over a coin nobody made, so
## they take the same spends in any order. What they keep is kept once
## the whole spend is taken and before anything is said, so whoever
## hears it and speaks again is judged against it, and nothing is kept
## for a spend any of them refuses. See split.nim for the two halves of
## the coins in either order.
##
## A pool is `sealed` in front of `once`, with none of the coins: where
## there are branches, which coins are unspent depends on the branch.

import ./[coin, door]
export coin, door

template spends(judging: untyped): Rule =
  ## a rule over spends, with `body`, the transaction, `c` and `msg`
  ## bound. It takes anything else, which `sealed` refuses
  proc(c {.inject.}: Conversation, msg {.inject.}: Msg): bool =
    if not msg.value.isSpend: return true
    let body {.inject.} = msg.value[1]
    judging

proc sealed*(): Rule =
  door proc(v: Value): Value =
    if not v.isSpend: bl"not-a-spend"
    elif not Signed.load(v).holds: bl"bad-signature"
    else: Value()

proc known*(made: BDict): Rule = spends:
  for at in body[1].items:
    if at notin made: return c.refusing(msg, bl"(no-such-coin $at)")
  true

proc unspent*(spent: BSet): Rule = spends:
  let seen = newBSet()
  for at in body[1].items:
    if at in spent or at in seen: return c.refusing(msg, bl"(spent $at)")
    seen.incl at
  true

proc theirs*(made: BDict): Rule = spends:
  let signer = msg.value.signer
  for at in body[1].items:
    if at in made and made[at][1] != signer:
      return c.refusing(msg, bl"(not-theirs $at)")
  true

proc covered*(made: BDict): Rule = spends:
  var (spends, makes) = (0, 0)
  for at in body[1].items:
    if at in made: spends += made[at][2].num.toInt
  for each in body[2].items: makes += each[2].num.toInt
  makes <= spends or c.refusing(msg, bl"(uncovered $spends $makes)")

proc spending*(spent: BSet): Rule = spends:
  let ats = body[1].items.data
  c.keep:
    for at in ats: spent.incl at
  true

proc making*(made: BDict): Rule = spends:
  let (id, coins) = (body.idOf, body[2].items.data)
  c.keep:
    for n, each in coins: made[bl"(at $id $n)"] = each
  true

proc newLedger*(genesis: Value, spends: openArray[Value] = []): Conversation =
  ## a ledger whose first coins are what `genesis` makes, holding what
  ## `spends` spent and made, taken as they are
  let k = newCoins(genesis)
  for spend in spends: k.apply spend[1]
  Conversation(rule: all(sealed(), known(k.made), unspent(k.spent), theirs(k.made),
                         covered(k.made), spending(k.spent), making(k.made),
                         asSaid(toSpeaker = true)))

proc newPool*(): Conversation =
  ## signed spends, each once, two spends of one coin alike
  Conversation(rule: all(sealed(), once(newBSet())))
