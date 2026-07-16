{.experimental: "strictFuncs".}

## clave is a minimal attestation value dialect.
## It offers keypairs, signatures, and signed values.
##
## Signatures cover a value's CE bytes, so what is attested is the
## value itself. The dialect is three shapes:
##
##   Don't send this around silly!
##   But keypairs are also values
##   (keypair <scheme> #[seed] #[public])
##   
##   A self contained signature
##   (signature <scheme> #[sig] #[public])
##
##   A pair that travels as one value
##   (signed <value> <signature>)
##
## Scheme is eddsa-blake2b (monocypher's EdDSA). This can be extended
## to support other schemes later, but i'm one person! This is also
## what the scheme slot is for.

import std/options
import monocypher
import ../values
import ../codec/encode
export options, values

const Scheme* = "eddsa-blake2b"

type
  Seed* = monocypher.Seed
  Signature* = monocypher.Signature
  Key* = monocypher.Key

  Keypair* = object
    seed*: Seed
    secret: EddsaPrivateKey
    public*: Key

func keypairFromSeed*(seed: Seed): Keypair =
  # monocypher wipes the seed it derives from, and Nim passes arrays
  # by hidden pointer, so the wipe would reach the caller's copy
  result.seed = seed
  var scratch = seed
  let (secret, public) = crypto_eddsa_key_pair(scratch)
  result.secret = secret
  result.public = public

func sign*(kp: Keypair; v: Value): Signature =
  crypto_eddsa_sign(kp.secret, encode(v))

# ================ VOCABULARY ================

func signature*(scheme: string; sig, pub: openArray[byte]): Value =
  record(sym"signature", sym(scheme), bytes(@sig), bytes(@pub))

func signed*(v: sink Value; sig: Value): Value =
  record(sym"signed", v, sig)

func keypair*(scheme: string; seed, pub: openArray[byte]): Value =
  record(sym"keypair", sym(scheme), bytes(@seed), bytes(@pub))

func signedValue*(kp: Keypair; v: Value): Value =
  ## v, wrapped with its attestation.
  signed(v, signature(Scheme, sign(kp, v), kp.public))

# ================ RECOGNITION ================

func fixedBytes(v: Value; n: int): bool =
  v.kind == bBytes and v.bytes.len == n

func toKeypair*(v: Value): Option[Keypair] =
  ## Recognizes (keypair eddsa-blake2b #[32] #[32]); the secret is
  ## re-derived from the seed.
  if v.kind == bRecord and v.items.len == 4 and
     v.items[0] == sym"keypair" and v.items[1] == sym(Scheme) and
     v.items[2].fixedBytes(32) and v.items[3].fixedBytes(32):
    var seed: Seed
    copyMem(addr seed[0], addr v.items[2].bytes[0], 32)
    some keypairFromSeed(seed)
  else:
    none Keypair

func isSigned*(v: Value): bool =
  ## Shape only: (signed <value> (signature eddsa-blake2b #[64] #[32])).
  ## Whether the signature HOLDS is verifySigned's business.
  if v.kind != bRecord or v.items.len != 3 or v.items[0] != sym"signed":
    return false
  let sig = v.items[2]
  sig.kind == bRecord and sig.items.len == 4 and
    sig.items[0] == sym"signature" and sig.items[1] == sym(Scheme) and
    sig.items[2].fixedBytes(64) and sig.items[3].fixedBytes(32)

func verifySigned*(v: Value): Option[Value] =
  ## The inner value, iff its signature checks out over its CE bytes.
  if not isSigned(v):
    return none Value
  let sigRecord = v.items[2]
  var
    sig: Signature
    pub: Key
  copyMem(addr sig[0], addr sigRecord.items[2].bytes[0], 64)
  copyMem(addr pub[0], addr sigRecord.items[3].bytes[0], 32)
  if crypto_eddsa_check(sig, pub, encode(v.items[1])):
    some v.items[1]
  else:
    none Value
