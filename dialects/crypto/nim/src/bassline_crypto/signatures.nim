import std/sysrand
import bassline
import ./[digests, eddsa]

refuseWith BasslineError

const
  EddsaBlake2b* = "eddsa-blake2b"
  Ed25519* = "ed25519"

type
  PublicKey* = object
    scheme*, key*: string

  Keypair* = object
    scheme*, seed*, pubkey*: string

  Signature* = object
    scheme*, sig*, pubkey*: string

  Signed* = object
    value*: Node
    sig*: Signature

func canCheck*(scheme: string): bool =
  scheme in [EddsaBlake2b, Ed25519]

proc hashOf(scheme: string): EddsaHash =
  case scheme
  of EddsaBlake2b: EddsaHash.Blake2b
  of Ed25519: EddsaHash.Sha512
  else: refuse "no signature scheme " & scheme

proc keypairFromSeed*(seed: string, scheme = Ed25519): Keypair =
  guard seed.len == 32, "a seed is 32 bytes"
  var scratch: Seed
  scratch[0 .. ^1] = seed.toBytes
  let (_, pubkey) = scheme.hashOf.keyPair(scratch)
  Keypair(scheme: scheme, seed: seed, pubkey: pubkey.toString)

proc newKeypair*(scheme = Ed25519): Keypair =
  var seed: Seed
  guard urandom(seed), "no randomness to make a seed from"
  keypairFromSeed(seed.toString, scheme)

proc secret(kp: Keypair): SecretKey =
  guard kp.seed.len == 32, "a seed is 32 bytes"
  var scratch: Seed
  scratch[0 .. ^1] = kp.seed.toBytes
  kp.scheme.hashOf.keyPair(scratch)[0]

proc sign*(kp: Keypair, n: Node): Signature =
  let
    bytes = n.ce
    sig = kp.scheme.hashOf.sign(kp.secret, bytes.toBytes)
  Signature(scheme: kp.scheme, sig: sig.toString, pubkey: kp.pubkey)

proc signed*(kp: Keypair, n: sink Node): Signed =
  let sig = kp.sign(n)
  Signed(value: n, sig: sig)

proc holds*(s: Signature, n: Node): bool =
  if not s.scheme.canCheck or s.sig.len != 64 or s.pubkey.len != 32:
    return false
  var
    sig: Sig
    key: Key
  sig[0 .. ^1] = s.sig.toBytes
  key[0 .. ^1] = s.pubkey.toBytes
  let bytes = n.ce
  s.scheme.hashOf.check(sig, key, bytes.toBytes)

proc holds*(s: Signed): bool =
  s.sig.holds(s.value)

func publicKey*(kp: Keypair): PublicKey =
  PublicKey(scheme: kp.scheme, key: kp.pubkey)

func publicKey*(s: Signature): PublicKey =
  PublicKey(scheme: s.scheme, key: s.pubkey)

proc toNode*(k: sink PublicKey): Node =
  let (scheme, key) = (Sym(k.scheme), Bytes(k.key))
  bl"(key $scheme $key)"

proc toNode*(s: sink Signature): Node =
  let (scheme, sig, pubkey) = (Sym(s.scheme), Bytes(s.sig), Bytes(s.pubkey))
  bl"(signature $scheme $sig $pubkey)"

proc toNode*(s: sink Signed): Node =
  let sig = s.sig.toNode
  bl"(signed $s.value $sig)"

proc toNode*(kp: sink Keypair): Node =
  let (scheme, seed, pubkey) = (Sym(kp.scheme), Bytes(kp.seed), Bytes(kp.pubkey))
  bl"(keypair $scheme $seed $pubkey)"

proc toPublicKey*(n: sink Node): PublicKey =
  matchValue n:
  of "(key $scheme $k)":
    guard scheme.isKind(bSym, unmarked) and k.isKind(bBytes, unmarked), "not a key: " & $n
    PublicKey(scheme: scheme.asValue.vstr, key: k.asValue.vstr)
  else:
    refuse "not a key: " & $n

proc toSignature*(n: sink Node): Signature =
  matchValue n:
  of "(signature $scheme $sig $pubkey)":
    guard scheme.isKind(bSym, unmarked) and sig.isKind(bBytes, unmarked) and pubkey.isKind(bBytes, unmarked),
      "not a signature: " & $n
    Signature(scheme: scheme.asValue.vstr, sig: sig.asValue.vstr, pubkey: pubkey.asValue.vstr)
  else:
    refuse "not a signature: " & $n

proc toSigned*(n: sink Node): Signed =
  matchValue n:
  of "(signed $value $sig)": Signed(value: value, sig: sig.toSignature)
  else: refuse "not a signed value: " & $n

proc toKeypair*(n: sink Node): Keypair =
  matchValue n:
  of "(keypair $scheme $seed $pubkey)":
    guard scheme.isKind(bSym, unmarked) and seed.isKind(bBytes, unmarked) and pubkey.isKind(bBytes, unmarked),
      "not a keypair: " & $n
    let kp = Keypair(scheme: scheme.asValue.vstr, seed: seed.asValue.vstr, pubkey: pubkey.asValue.vstr)
    guard kp.scheme.canCheck and kp.seed.len == 32 and kp.pubkey.len == 32,
      "not a keypair this can sign with: " & $n
    kp
  else:
    refuse "not a keypair: " & $n
