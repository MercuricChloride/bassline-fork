include pkg/prelude

## clave is a minimal attestation value dialect.
## It offers keypairs, signatures, and signed values.
##
## Signatures cover a value's CE bytes, so what is attested is the
## value itself. The dialect is three shapes:
##
##   Keypairs as a value
##   But don't send this around silly!
##   (keypair <scheme> 0x<seed> 0x<public>)
##
##   A self contained signature
##   (signature <scheme> 0x<sig> 0x<public>)
##
##   A pair that travels as one value
##   (signed <value> <signature>)
##
## Scheme is eddsa-blake2b (monocypher's EdDSA). This can be extended
## to support other schemes later, but i'm one person! This is also
## what the scheme slot is for.

import ../../core
import ../dialect
import ./eddsa

const Scheme* = "eddsa-blake2b"

type
  Seed* = eddsa.Seed
  Key* = eddsa.Key

  Keypair* = object
    seed*: Seed
    secret: SecretKey
    public*: Key

  KeypairShape {.blRecord: "keypair".} = object
    scheme: Lit[Scheme]
    seed: Seed
    public: Key

  Signature* {.blRecord: "signature".} = object
    scheme*: Lit[Scheme]
    sig*: Sig
    public*: Key

  Signed* {.blRecord: "signed".} = object
    value*: Value
    signature*: Signature

func keypairFromSeed*(seed: Seed): Keypair =
  # monocypher wipes the seed it derives from, and Nim passes arrays
  # by hidden pointer, so the wipe would reach the caller's copy
  result.seed = seed
  var scratch = seed
  let (secret, public) = keyPair(scratch)
  result.secret = secret
  result.public = public

func sign*(kp: Keypair, x: Value): Sig =
  eddsa.sign(kp.secret, x.encode)

func toValue*(kp: Keypair): Value =
  KeypairShape(seed: kp.seed, public: kp.public).toValue

func fromValue*(v: Value, t: typedesc[Keypair]): Option[Keypair] =
  ## Recognizes (keypair eddsa-blake2b 0x<32 bytes> 0x<32 bytes>).
  let kv = fromValue(v, KeypairShape)
  if kv.isSome:
    some keypairFromSeed(kv.get.seed)
  else:
    none Keypair

func signedValue*(kp: Keypair, x: Value): Value =
  ## returns x wrapped with its attestation
  let sig = Signature(sig: sign(kp, x), public: kp.public)
  Signed(value: x, signature: sig).toValue

func holds*(s: Signed): bool =
  check(s.signature.sig, s.signature.public, encode(s.value))