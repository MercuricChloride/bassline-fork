{.experimental: "strictFuncs".}

import values

export values

type
  PayloadSize = enum sm, md, lg
  InvalidPayloadSize* = object of CatchableError

const MAX_PAYLOAD_SIZE: uint32 = high(uint32)

func payloadSize(len: int): PayloadSize =
  case len
  of 0 .. 6: sm
  of 7 .. 254: md
  else:
    if len <= int(MAX_PAYLOAD_SIZE):
      lg
    else:
      raise newException(InvalidPayloadSize, "payload too large: " & $len)

func write*(buf: var seq[byte], b: byte) =
  buf.add b

func write*(buf: var seq[byte], bytes: openArray[byte]) =
  buf.add bytes

func encodeInto*[W](value: Value, w: var W) =
  ## Writes the CE bytes of `value` to any writer providing
  ## `write(var W, byte)` and `write(var W, openArray[byte])`.
  mixin write
  let
    len = value.payloadLength
    hTag = byte(value.tag) shl 4
    hMark = byte(value.marked) shl 3
    hLen = byte(min(len, 7)) # 7 being last 3 bits hi 111

  # the first byte is [tag:4][mark:1][len:3]
  w.write byte(hTag or hMark or hLen)

  # then comes the length byte(s) if any
  case payloadSize(len)
  of sm: discard
  of md:
    # medium sizes fit into a single byte
    w.write byte(len)
  of lg:
    # large sizes have their medium byte maxed out
    w.write byte(0xFF)
    # followed by a 4 byte big endian length
    w.write byte((len shr 24) and 0xFF)
    w.write byte((len shr 16) and 0xFF)
    w.write byte((len shr 8) and 0xFF)
    w.write byte(len and 0xFF)

  case value.kind
  of bNil: discard
  of bNum:
    let s = string(value.num)
    w.write s.toOpenArrayByte(0, s.high)
  of bText, bSym:
    w.write value.text.toOpenArrayByte(0, value.text.high)
  of bBytes:
    w.write value.bytes
  of bList, bRecord:
    for item in value.items:
      item.encodeInto w
    w.write END_BYTE
  of bSet:
    for el in value.elements:
      el.encodeInto w
    w.write END_BYTE
  of bDict:
    for (key, val) in value.entries:
      key.encodeInto w
      val.encodeInto w
    w.write END_BYTE

func encode*(value: Value): seq[byte] =
  value.encodeInto(result)
