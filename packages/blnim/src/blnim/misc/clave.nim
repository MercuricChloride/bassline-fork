{.experimental: "strictFuncs".}

## clave is a minimal attestation value dialect.
## It offers keypairs, signatures, and signed values.
##
## Signatures cover a value's CE bytes, so what is attested is the
## value itself. The dialect is three shapes:
##
##   Keypairs as a value
##   But don't send this around silly!
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

import monocypher
import ../dialect
import ../codec
export dialect

const Scheme* = "eddsa-blake2b"

type
  Seed* = monocypher.Seed
  Key* = monocypher.Key

  Keypair* = object
    seed*: Seed
    secret: EddsaPrivateKey
    public*: Key

  KeypairShape {.blRecord: "keypair".} = object
    scheme: Lit[Scheme]
    seed: Seed
    public: Key

  Signature* {.blRecord: "signature".} = object
    scheme*: Lit[Scheme]
    sig*: monocypher.Signature
    public*: Key

  Signed* {.blRecord: "signed".} = object
    value*: Value
    signature*: Signature

func keypairFromSeed*(seed: Seed): Keypair =
  # monocypher wipes the seed it derives from, and Nim passes arrays
  # by hidden pointer, so the wipe would reach the caller's copy
  result.seed = seed
  var scratch = seed
  let (secret, public) = crypto_eddsa_key_pair(scratch)
  result.secret = secret
  result.public = public

func sign*[T: ValueLike](kp: Keypair, x: T): monocypher.Signature =
  crypto_eddsa_sign(kp.secret, encode(toValue(x)))

func toValue*(kp: Keypair): Value =
  KeypairShape(seed: kp.seed, public: kp.public).toValue

func fromValue*(v: Value, t: typedesc[Keypair]): Option[Keypair] =
  ## Recognizes (keypair eddsa-blake2b #[32] #[32]).
  let kv = fromValue(v, KeypairShape)
  if kv.isSome:
    some keypairFromSeed(kv.get.seed)
  else:
    none Keypair

func signedValue*[T: ValueLike](kp: Keypair, x: T): Value =
  ## x as a value, wrapped with its attestation.
  let v = toValue(x)
  let sig = Signature(sig: sign(kp, v), public: kp.public)
  toValue(Signed(value: v, signature: sig))

func holds*(s: Signed): bool =
  crypto_eddsa_check(s.signature.sig, s.signature.public, encode(s.value))
