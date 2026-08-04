include pkg/prelude
import checksums/sha2
import monocypher
import ../core
import ./[dialect, common]

# ================ BLAKE2B ================
# 
# WARNING! EXTREMELY HACKY SHIT AHEAD!
# Monocypher has support for incremental blake2b hashing
# but the nim wrapper we are using doesn't expose it
# THIS IS NOT GOOD AND I WILL FIX THIS LATER!

type Blake2bCtx = object
  hash: array[8, uint64]
  inputOffset: array[2, uint64]
  input: array[16, uint64]
  inputIdx: uint
  hashSize: uint

proc blake2bInit(ctx: ptr Blake2bCtx, hashSize: uint) {.
  importc: "crypto_blake2b_init", cdecl.}

proc blake2bUpdate(ctx: ptr Blake2bCtx, message: ptr uint8, size: uint) {.
  importc: "crypto_blake2b_update", cdecl.}

proc blake2bFinal(ctx: ptr Blake2bCtx, hash: ptr uint8) {.
  importc: "crypto_blake2b_final", cdecl.}

type Blake2bWriter = object
  ctx: Blake2bCtx

func write(w: var Blake2bWriter, b: byte) =
  var one = b
  {.cast(noSideEffect).}:
    blake2bUpdate(addr w.ctx, addr one, 1)

func write(w: var Blake2bWriter, bytes: openArray[byte]) =
  if bytes.len > 0:
    {.cast(noSideEffect).}:
      blake2bUpdate(addr w.ctx, cast[ptr uint8](addr bytes[0]), uint(bytes.len))

func initBlake2b(): Blake2bWriter =
  {.cast(noSideEffect).}:
    blake2bInit(addr result.ctx, 32)

func finish(w: var Blake2bWriter): array[32, byte] =
  {.cast(noSideEffect).}:
    blake2bFinal(addr w.ctx, cast[ptr uint8](addr result[0]))

func blake2b*(v: Value): array[32, byte] =
  ## The blake2b-256 of the value's CE bytes
  var w = initBlake2b()
  v.encodeInto(w)
  w.finish()

func blake2b*(bytes: openArray[byte]): array[32, byte] =
  ## Over raw bytes. For bytes that are already a value's CE, this
  ## equals blake2b of the value
  var w = initBlake2b()
  w.write(bytes)
  w.finish()

# ================ SHA256 ================

type Sha256Writer = object
  ctx: ShaStateStatic[Sha_256]

func write(w: var Sha256Writer, b: byte) =
  w.ctx.update([char(b)])

func write(w: var Sha256Writer, bytes: openArray[byte]) =
  if bytes.len > 0:
    w.ctx.update(
      cast[ptr UncheckedArray[char]](addr bytes[0]).toOpenArray(0, bytes.len - 1)
    )

func sha256*(v: Value): array[32, byte] =
  ## The sha256 of the value's CE bytes
  var w = Sha256Writer(ctx: initSha_256())
  v.encodeInto(w)
  let d = w.ctx.digest()
  copyMem(addr result[0], addr d[0], 32)

func sha256*(bytes: openArray[byte]): array[32, byte] =
  ## Over raw bytes. For bytes that are already a value's CE, this
  ## equals sha256 of the value
  var w = Sha256Writer(ctx: initSha_256())
  w.write(bytes)
  let d = w.ctx.digest()
  copyMem(addr result[0], addr d[0], 32)

const DigestAlgo* = "blake2b"

func digest*(x: Value): Digest =
  Digest(algo: Sym(DigestAlgo), hash: @(blake2b x))

func verifies*(d: Digest, ce: openArray[byte]): bool =
  case $d.algo
  of "blake2b": @(blake2b(ce)) == d.hash
  of "sha256": @(sha256(ce)) == d.hash
  else: false