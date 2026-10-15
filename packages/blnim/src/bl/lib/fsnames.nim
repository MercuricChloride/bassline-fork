##[
  Names for content. An alias is someone's word that a name names some
  content or a tree, said as a signed put on a jam:

    ((alias NAME) D)     NAME names D, a (digest blake2b H)

  Anyone may put one, and none of them is the alias. What a name names
  to a reader is the answers it has been told under (alias NAME), signed
  by keys it trusts, the newest in its own order first, each digest
  once. A name several keys have named, or one key several times, gives
  several answers, and taking one is the reader's choice. An alias nobody
  signed names nothing to anyone, since no key vouches for it.

    (aliases NAME)       NAME has been aliased

  lists the names, as (rooms ROOM) lists rooms, so a reader that can't
  list a jam asks (aliases) to learn which names to ask after.

  A path NAME/a/b is walked from each digest NAME names through the
  trees under it, a step a name, so each answer gives its own. A path may
  begin with a digest instead of a name.
]##

import std/[algorithm, options, sequtils]
import ../[core, queries]
import ./[fs, jam]
import ./crypto/clave

let
  AliasHead* = sym"alias"
  AliasesQ* = sym"aliases"  ## the names that have been aliased

proc aliasQ*(name: Value): Value =
  ## the question an alias for `name` answers, (alias NAME)
  initRec(@[AliasHead, name])

proc alias*(kp: Keypair, name, d: Value): Value =
  ## the value that puts `d` as what `name` names, signed by `kp`
  kp.signed(initRec(@[aliasQ(name), d])).toValue

type Alias* = object
  ## an alias as a reader was told it
  name*: Value
  digest*: Value   ## what it names
  signer*: Key     ## who says so
  rank*: int       ## where the jam heard it

proc aliasOf*(h: Heard): Option[Alias] =
  ## the alias a told answer is, if it is one: a signed put to
  ## (alias NAME) whose answer is a digest
  if h.signer.isNone or not h.q.isKind(bRec, unmarked) or h.q.items.len != 2 or
     h.q.head != AliasHead or not Digest.fits(h.said):
    return none(Alias)
  some Alias(name: h.q.items[1], digest: h.said, signer: h.signer.get, rank: h.rank)

proc aliasesOf*(local: BVar[Value, Ranked[Value]], name: Value): seq[Alias] =
  ## every alias for `name` a reader has been told, whoever signed it,
  ## the newest in its order first
  result = local.heardIn(aliasQ(name)).filterMaps(aliasOf(it)).toSeq
  result.reverse

proc trusting*(keys: openArray[Key]): (Key) -> bool =
  ## trusts these keys and no others
  let keys = @keys
  (k: Key) => k in keys

proc names*(local: BVar[Value, Ranked[Value]], trusts: (Key) -> bool): Search[Value, Value] =
  ## a name to the digests it names by keys `trusts` takes, from what a
  ## reader has been told when it is asked, the newest first, each once
  newSearch[Value, Value]((name: Value) =>
    local.aliasesOf(name).filterIt(trusts(it.signer)).mapIt(it.digest).deduplicate.initStream)

proc resolve*(names, content: Search[Value, Value], root: Value,
              path: openArray[string]): Stream[Value] =
  ## the entries `path` names from `root`: from `root` itself when it is
  ## a digest, else from each digest the name `root` names, in the order
  ## `names` gives them. A digest is given bare when `path` is empty, and
  ## a step is taken only through a tree `content` has
  let path = @path
  let roots = if Digest.fits(root): just(root) else: names.ask(root)
  roots.flatMap((d: Value) => content.walk(d, path))

proc lacking*(content: Search[Value, Value], root: Value,
              path: openArray[string]): seq[Value] =
  ## the trees walking `path` from `root`, a digest or a directory entry,
  ## goes through and `content` has no answer for that checks, as far as
  ## it can see: past a tree it lacks nothing more is known
  if path.len == 0: return
  let d = if DirEntry.fits(root): named(root).get else: root
  if not Digest.fits(d): return
  let t = content.answerOf(d)
  if t.isNone: return @[d]
  if not FsTree.fits(t.get): return
  for (name, e) in FsTree.load(t.get).entries:
    if name == path[0]:
      return content.lacking(e, path.toOpenArray(1, path.high))
