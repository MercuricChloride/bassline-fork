## The canonical encoding (data-model.org, "Canonical Binary Encoding") as
## a grammar, building through `Make` like the text grammar. What can only
## be seen as the bytes arrive is checked here: a known tag, length bits
## only where there is a length, a minimal length form, a payload that is
## all there, a frame closed by END, a record with a head, a key with its
## value, an integer spelled canonically. Order, repeats and UTF-8 are the
## pass in `values`.

import petit_parser
import ../core/shared
import ./bassline_text

type Header = tuple[tag, lll: uint8, mark: bool]

proc headerData(b: byte): Header =
  let
    tag: uint8 = b shr 4
    mark: bool = (b and 0x08) != 0
    lll: uint8 = b and 0x07
  (tag, lll, mark)

func length(data: seq[byte], pos: var int, lll: uint8): int =
  ## The payload length after a header: `lll` itself, or the medium or
  ## large form it announces, read from `pos`. -1 when that is cut short,
  ## -2 when a shorter form would have done.
  result = int lll
  if result < 7: return
  if pos >= data.len: return -1
  result = data[pos].int
  inc pos
  if result == 255:
    if pos + 4 > data.len: return -1
    result = 0
    for i in 0 .. 3: result = result shl 8 or data[pos + i].int
    pos += 4
    if result < 255: return -2
  elif result < 7: return -2

proc flat[V](entries: sink seq[(V, V)]): seq[V] =
  result = newSeqOfCap[V](2 * entries.len)
  for e in entries.mitems:
    result.add move e[0]
    result.add move e[1]

proc ceValue*[V](make: Make[V]): ByteParser[V] =
  ## One header read, then a dispatch on its tag.
  let
    value = undefined[seq[byte], V]("value")
    stop = ch(byte(0xA0))
    members = (value.star & stop).pick(0)
    entries = ((value & value).star & stop).pick(0)
    header = failure[seq[byte], Nothing]("a value header")
    payload = failure[seq[byte], Nothing]("a whole payload")
    minimal = failure[seq[byte], Nothing]("a minimal length")
    integer = failure[seq[byte], Nothing]("a canonical integer")
    headed = failure[seq[byte], Nothing]("a record head")

  proc scalar(head: Header, ctx: Context[seq[byte]]): Result[V] =
    var pos = ctx.pos
    let n = ctx.input.source.length(pos, head.lll)
    if n == -2: return fail[seq[byte], V](minimal, ctx)
    if n < 0 or pos + n > ctx.input.stop: return fail[seq[byte], V](payload, ctx.at(pos))
    let data = ctx.input.source[pos ..< pos + n]
    case head.tag
    of 2:
      if not isValidInt(data): return fail[seq[byte], V](integer, ctx.at(pos))
      succeed(make.atom(bNum, data.toString, head.mark), pos + n)
    of 3: succeed(make.atom(bText, data.toString, head.mark), pos + n)
    of 4: succeed(make.atom(bSym, data.toString, head.mark), pos + n)
    else: succeed(make.bytes(data, head.mark), pos + n)

  proc framed(head: Header, ctx: Context[seq[byte]]): Result[V] =
    let kind = Kind(head.tag - 1)
    if kind == bDict:
      var r = entries.parseOn(ctx)
      if not r.isSuccess: return failedAs(V, r)
      succeed(make.frame(bDict, flat(r.take), head.mark), r.pos)
    else:
      var r = members.parseOn(ctx)
      if not r.isSuccess: return failedAs(V, r)
      var items = r.take
      if kind == bRec and items.len == 0: return fail[seq[byte], V](headed, ctx)
      succeed(make.frame(kind, items, head.mark), r.pos)

  let node = anyByte().map(headerData).callCC(
    proc (next: ByteParser[Header], ctx: Context[seq[byte]]): Result[V] =
      let h = next.parseOn(ctx)
      if not h.isSuccess: return failedAs(V, h)
      let head = h.value
      case head.tag
      of 2, 3, 4, 5: scalar(head, ctx.at(h.pos))
      of 1, 6, 7, 8, 9:
        if head.lll != 0: fail[seq[byte], V](header, ctx)
        elif head.tag == 1: succeed(make.atom(bNil, "", head.mark), h.pos)
        else: framed(head, ctx.at(h.pos))
      else: fail[seq[byte], V](header, ctx))
  value.define(node)
  value

proc ceParser*[V](make: Make[V]): ByteParser[V] =
  ## Exactly one value.
  ceValue(make).complete.resolve

proc ceDocument*[V](make: Make[V]): ByteParser[seq[V]] =
  ## A bare concatenation of values, as in a `.blb` file.
  ceValue(make).star.complete.resolve
