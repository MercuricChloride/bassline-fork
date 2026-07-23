{.experimental: "strictFuncs".}

import checksums/sha2
import ../core
import ./[dialect, common]

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

func digest*[T: ValueLike](x: T): Digest =
  ## A value's name by content
  Digest(algo: Sym"sha256", hash: @(sha256 toValue(x)))