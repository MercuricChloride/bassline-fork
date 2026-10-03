import ../../core
import ../blmacro

refuseWith ValueError

proc fields*(v, head: Value, n: int): seq[Value] =
  ## the fields of `(head F1 … Fn)`, read exactly: unmarked, with that
  ## head and n fields, no more. A field more would ride along unread,
  ## and unsigned where a signature covers the value.
  guard v.kind == bRec and not v.mark and v.items.len == n + 1 and
    v.head == head, "not (" & $head & " …) with " & $n & " fields"
  v.items.data[1 .. n]

proc fill*[N: static int](dest: var array[N, byte], v: Value, what: string) =
  ## dest from v, which must be unmarked bytes exactly N long
  guard v.kind == bBytes and not v.mark and v.bytes.len == N,
    "malformed " & what
  copyMem addr dest[0], addr v.bytes[0], N

let Scheme* = rv"eddsa-blake2b"

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
  bl shape(signature(scheme, sig, pubkey), {scheme, sig, pubkey})

func shape*(_: typedesc[Signed]): Value =
  bl shape(signed(value, sig), {value, sig})

proc fromValue*(T: typedesc[Signature], v: Value): Signature =
  let f = v.fields(bl signature, 3)
  guard f[0] == Scheme, "unknown scheme"
  result.scheme = Scheme
  result.sig.fill f[1], "sig"
  result.pubkey.fill f[2], "pubkey"

proc fromValue*(T: typedesc[Signed], v: Value): Signed =
  let f = v.fields(bl signed, 2)
  Signed(value: f[0], sig: Signature.fromValue f[1])

func toValue*(self: Signature): Value =
  bl signature(%self.scheme, %(@(self.sig)), %(@(self.pubkey)))

func toValue*(self: Signed): Value =
  bl signed(%self.value, %self.sig)

func shape*(_: typedesc[Keypair]): Value =
  bl shape(keypair(scheme, seed, pubkey), {scheme, seed, pubkey})

proc fromValue*(T: typedesc[Keypair], v: Value): Keypair =
  let f = v.fields(bl keypair, 3)
  guard f[0] == Scheme, "unknown scheme"
  result.scheme = Scheme
  result.seed.fill f[1], "seed"
  result.pubkey.fill f[2], "pubkey"

func toValue*(self: Keypair): Value =
  bl keypair(%self.scheme, %(@(self.seed)), %(@(self.pubkey)))