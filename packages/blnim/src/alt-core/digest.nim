include pkg/prelude
import nimcrypto/[blake2, sha2]
import ./types

const DigestBuf = 4096

type Blake2bWriter* = object
  ctx: Blake2bContext[256]
  buf: array[DigestBuf, byte]
  n: int

func flush(w: var Blake2bWriter) =
  if w.n > 0:
    w.ctx.update(w.buf.toOpenArray(0, w.n - 1))
    w.n = 0

proc write*(w: var Blake2bWriter, bytes: openArray[byte]): int =
  w.flush()
  w.ctx.update(bytes)

func finish(w: var Blake2bWriter): array[32, byte] =
  w.flush()
  discard w.ctx.finish(result)

func initBlake2b*(): Blake2bWriter =
  result.ctx.init()

proc blake2b*(b: openArray[byte]): array[32, byte] =
  mixin encode
  var w = initBlake2b()
  discard w.write(b)
  w.finish()

proc blake2b*(v: Value): array[32, byte] =
  mixin encode
  var w = initBlake2b()
  discard encode(w, v)
  w.finish()

proc blake2b*[V: Value](els: openArray[V]): array[32, byte] =
  ## digest of a sequence of values: their canonical
  ## encodings back to back
  mixin encode
  var w = initBlake2b()
  for el in els:
    discard encode(w, el)
  w.finish()