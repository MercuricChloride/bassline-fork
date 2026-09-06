import ../../core
import ../[blmacro, ops]

template refuse(msg: string) =
  raise newException(ValueError, msg)

let Scheme* = bl `eddsa-blake2b`

type
  Seed* = array[32, byte]
  Key* = array[32, byte]
  SecretKey* = array[64, byte]
  Sig* = array[64, byte]

  Keypair* = object
    scheme*: Value
    seed*: Seed
    pubkey*: Key
  
  Signature* = object
    scheme*: Value
    sig*: Sig
    pubkey*: Key
  
  Signed* = object
    value*: Value
    sig*: Signature

func shape*(_: typedesc[Signature]): Value =
  bl signature(!scheme, !sig, !pubkey)

func shape*(_: typedesc[Signed]): Value =
  bl signed(!value, !sig)

proc fromValue*(T: typedesc[Signature], v: Value): Signature =
  bind refuse
  var bindings: Value
  guard T.shape.extract(v, bindings), "invalid signature shape"
  let 
    scheme = bindings[bl scheme]
    sig = bindings[bl sig]
    pubkey = bindings[bl pubkey]
  guard scheme == Scheme, "unknown scheme"
  guard sig.kind == bBytes and sig.bytes.len == 64, "malformed sig"
  guard pubkey.kind == bBytes and pubkey.bytes.len == 32, "malformed pubkey"
  result.scheme = bindings[bl scheme]
  copyMem addr result.sig[0], addr sig.bytes[0], 64
  copyMem addr result.pubkey[0], addr pubkey.bytes[0], 32

proc fromValue*(T: typedesc[Signed], v: Value): Signed =
  bind refuse
  var bindings: Value
  guard T.shape.extract(v, bindings), "invalid signed shape"
  let
    value = bindings[bl value]
    sig = Signature.fromValue bindings[bl value]
  Signed(value: value, sig: sig)

func toValue*(self: Signature): Value =
  bl signature(%self.scheme, %(@(self.sig)), %(@(self.pubkey)))

func toValue*(self: Signed): Value =
  bl signed(%self.value, %self.sig)