include pkg/prelude

import nimcrypto/[blake2, sha2]
import pkg/core
import pkg/lib/obmcommon

# ================ BLAKE2B ================
#
# blake2b-256 streams through nimcrypto's Blake2bContext[256]; its init
# builds the parameter block from the bit width, so this is the real
# parameterized blake2b-256, not a truncation. monocypher remains the
# eddsa backend in clave.

# a staging buffer in front of the hasher, like ValueWriter's in
# front of the File: a deep value is tens of thousands of tiny
# writes, and each update call has a fixed cost
const DigestBuf = 4096

type Blake2bWriter = object
  ctx: Blake2bContext[256]
  buf: array[DigestBuf, byte]
  n: int

func flush(w: var Blake2bWriter) =
  if w.n > 0:
    w.ctx.update(w.buf.toOpenArray(0, w.n - 1))
    w.n = 0

func write(w: var Blake2bWriter, b: byte) =
  if w.n >= DigestBuf:
    w.flush()
  w.buf[w.n] = b
  inc w.n

func write(w: var Blake2bWriter, bytes: openArray[byte]) =
  if bytes.len >= DigestBuf:
    # big enough to be its own update; staging it would only copy it
    w.flush()
    w.ctx.update(bytes)
  elif bytes.len > 0:
    if w.n + bytes.len > DigestBuf:
      w.flush()
    copyMem(addr w.buf[w.n], addr bytes[0], bytes.len)
    w.n += bytes.len

func initBlake2b(): Blake2bWriter =
  result.ctx.init()

func finish(w: var Blake2bWriter): array[32, byte] =
  w.flush()
  discard w.ctx.finish(result)

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
  ctx: sha2.sha256
  buf: array[DigestBuf, byte]
  n: int

func flush(w: var Sha256Writer) =
  if w.n > 0:
    w.ctx.update(w.buf.toOpenArray(0, w.n - 1))
    w.n = 0

func write(w: var Sha256Writer, b: byte) =
  if w.n >= DigestBuf:
    w.flush()
  w.buf[w.n] = b
  inc w.n

func write(w: var Sha256Writer, bytes: openArray[byte]) =
  if bytes.len >= DigestBuf:
    w.flush()
    w.ctx.update(bytes)
  elif bytes.len > 0:
    if w.n + bytes.len > DigestBuf:
      w.flush()
    copyMem(addr w.buf[w.n], addr bytes[0], bytes.len)
    w.n += bytes.len

func initSha256(): Sha256Writer =
  result.ctx.init()

func sha256*(v: Value): array[32, byte] =
  ## The sha256 of the value's CE bytes
  var w = initSha256()
  v.encodeInto(w)
  w.flush()
  w.ctx.finish().data

func sha256*(bytes: openArray[byte]): array[32, byte] =
  ## Over raw bytes. For bytes that are already a value's CE, this
  ## equals sha256 of the value
  var w = initSha256()
  w.write(bytes)
  w.flush()
  w.ctx.finish().data

const DigestAlgo* = "blake2b"

func digest*(x: Value): Digest =
  Digest(algo: Sym(DigestAlgo), hash: @(blake2b x))

func knownAlgo*(algo: string): bool =
  ## the digest algos this build can check; `verifies` speaks exactly these
  case algo
  of "blake2b", "sha256": true
  else: false

func verifies*(d: Digest, ce: openArray[byte]): bool =
  case $d.algo
  of "blake2b": @(blake2b(ce)) == d.hash
  of "sha256": @(sha256(ce)) == d.hash
  else: false
