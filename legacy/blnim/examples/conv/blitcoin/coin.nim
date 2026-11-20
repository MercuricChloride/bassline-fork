## The values blitcoin speaks, and the readings every piece shares.
##
##   (coin KEY AMOUNT)       AMOUNT for whoever holds KEY
##   (at TXID N)             the Nth coin the transaction TXID made
##   (tx [AT …] [COIN …])    spends the coins it names, makes new ones
##   (signed TX SIGNATURE)   a spend: TX signed by the key of every coin
##                           it spends, with clave's `signed`
##
## KEY is a clave public key, 32 bytes, and AMOUNT a positive integer
## no larger than MaxAmount. TXID is the digest of the unsigned (tx …),
## so a coin is named by what made it, not by who signed it. `Coins`
## keeps them as two sets that only grow, every coin made and every
## coin spent, and takes in a transaction without judging it.

import std/[sequtils, strutils]
import bl/core
import bl/lib/crypto/[clave, digest]
export core, clave, digest

blet"{coin at tx}"

const MaxAmount* = 21_000_000 * 100_000_000

type Coins* = ref object
  made*: BDict  ## every coin made, by its (at TXID N)
  spent*: BSet  ## every (at TXID N) spent

var names = newBDict()  # for printing only: a key, and who holds it

proc person*(name: string): Keypair =
  ## a keypair seeded by its name, so every run has the same keys
  result = keypairFromSeed(blake2b(name.toBytes))
  names[toValue(result.pubkey)] = sym(name)

proc key*(kp: Keypair): Value = toValue(kp.pubkey)

proc idOf*(v: Value): Value =
  ## the digest a transaction or a block is named by
  v.digest(Blake2bAlgo).toValue

proc isAmount(v: Value): bool =
  v.isKind(bNum, unmarked) and v.num.isInt and v.num.toInt in 1 .. MaxAmount

proc isCoin*(v: Value): bool =
  v.isKind(bRec, unmarked) and v.len == 3 and v.head == coin and
    v[1].isKind(bBytes, unmarked) and v[1].bytes.len == 32 and v[2].isAmount

proc isAt*(v: Value): bool =
  v.isKind(bRec, unmarked) and v.len == 3 and v.head == at and
    Digest.fits(v[1]) and v[2].isKind(bNum, unmarked) and v[2].num.isInt

proc isTx*(v: Value): bool =
  v.isKind(bRec, unmarked) and v.len == 3 and v.head == tx and
    v[1].isKind(bList, unmarked) and v[1].items.data.allIt(it.isAt) and
    v[2].isKind(bList, unmarked) and v[2].len > 0 and
    v[2].items.data.allIt(it.isCoin)

proc isSpend*(v: Value): bool =
  Signed.fits(v) and v[1].isTx

proc signer*(spend: Value): Value =
  ## the key a spend is signed by, whether or not the signature holds
  toValue(Signed.load(spend).sig.pubkey)

proc pays*(kp: Keypair, spends: openArray[Value], coins: openArray[Value]): Value =
  ## a spend of `spends`, making `coins`, signed by kp
  let body = bl"(tx $spends $coins)"
  kp.signed(body).toValue

proc coinFor*(kp: Keypair, amount: int): Value =
  let k = kp.key
  bl"(coin $k $amount)"

proc bodyOf*(v: Value): Value =
  ## the transaction itself, signed or not
  if v.head == tx: v else: v[1]

proc atOf*(v: Value, n: int): Value =
  ## the Nth coin a transaction makes, signed or not
  let id = v.bodyOf.idOf
  bl"(at $id $n)"

proc apply*(c: Coins, body: Value) =
  ## takes in what a transaction spends and makes, unjudged
  let id = body.idOf
  for each in body[1].items: c.spent.incl each
  for n, each in body[2].items.data: c.made[bl"(at $id $n)"] = each

proc newCoins*(genesis: Value): Coins =
  ## the coins the unsigned genesis transaction makes
  result = Coins(made: newBDict(), spent: newBSet())
  result.apply genesis

proc held*(c: Coins): BDict =
  ## what each key holds unspent
  result = newBDict()
  for at, each in c.made:
    if at notin c.spent:
      let had = if each[1] in result: result[each[1]].num.toInt else: 0
      result[each[1]] = num(had + each[2].num.toInt)

proc brief*(v: Value): Value =
  ## v for printing: a known key as who holds it, a signature as its
  ## key, a digest as # and its first two bytes
  case v.kind
  of bBytes:
    if v in names: names[v]
    else: sym("#" & v.bytes[0 .. 1].mapIt(it.toHex(2)).join.toLowerAscii)
  of bRec:
    if Digest.fits(v): brief(v[2])
    elif Signature.fits(v): brief(v[3])
    else: initRec(v.items.data.mapIt(brief(it)), v.mark)
  of bList: initList(v.items.data.mapIt(brief(it)), v.mark)
  of bDict:
    var entries: seq[(Value, Value)]
    for k, each in v.dict: entries.add (brief(k), brief(each))
    initDict(entries, v.mark)
  else: v
