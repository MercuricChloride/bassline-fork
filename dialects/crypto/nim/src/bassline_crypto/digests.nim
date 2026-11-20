import nimcrypto/[blake2, keccak, sha2]
import bassline

refuseWith BasslineError

const
  Blake2bAlgo* = "blake2b"
  Sha256Algo* = "sha256"
  Keccak256Algo* = "keccak256"

type Digest* = object
  algo*: string
  hash*: string

proc ce*(n: Node): string =
  n.write(result)

func sha256*(bytes: openArray[byte]): string =
  var ctx: sha2.sha256
  ctx.init()
  ctx.update(bytes)
  ctx.finish().data.toString

func blake2b*(bytes: openArray[byte]): string =
  # BLAKE2b with a 32 byte output, not a truncation of the 64 byte one
  var ctx: Blake2bContext[256]
  ctx.init()
  ctx.update(bytes)
  ctx.finish().data.toString

func keccak256*(bytes: openArray[byte]): string =
  # Keccak-256 padded as Keccak was before SHA-3 changed the padding, which
  # is what Ethereum calls it
  var ctx: keccak.keccak256
  ctx.init()
  ctx.update(bytes)
  ctx.finish().data.toString

func canHash*(algo: string): bool =
  algo in [Blake2bAlgo, Sha256Algo, Keccak256Algo]

proc hash*(bytes: openArray[byte], algo: string): string =
  case algo
  of Blake2bAlgo: blake2b bytes
  of Sha256Algo: sha256 bytes
  of Keccak256Algo: keccak256 bytes
  else: refuse "no hash algorithm " & algo

proc digest*(n: Node, algo: string): Digest =
  let bytes = n.ce
  Digest(algo: algo, hash: hash(bytes.toBytes, algo))

proc verifies*(d: Digest, ce: openArray[byte]): bool =
  d.algo.canHash and hash(ce, d.algo) == d.hash

proc verifies*(d: Digest, n: Node): bool =
  let bytes = n.ce
  d.verifies(bytes.toBytes)

proc toNode*(d: sink Digest): Node =
  let (algo, h) = (Sym(d.algo), Bytes(d.hash))
  bl"(digest $algo $h)"

proc toDigest*(n: sink Node): Digest =
  matchValue n:
  of "(digest $algo $h)":
    guard algo.isKind(bSym, unmarked) and h.isKind(bBytes, unmarked), "not a digest: " & $n
    Digest(algo: algo.asValue.vstr, hash: h.asValue.vstr)
  else:
    refuse "not a digest: " & $n
