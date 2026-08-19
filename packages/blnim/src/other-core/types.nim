include pkg/prelude
import ./validation

const
  EndByte* = 0xA0'u8

type
  RefuseError* = object of CatchableError
  UaBytes* = UncheckedArray[byte]
  Kind* = enum
    bInvalid,
    bNil,
    bNum, bStr, bSym, bBytes
    bList, bRec, bDict, bSet

const
  ScalarKinds* = {bNum, bStr, bSym, bBytes}
  FrameKinds* = {bList, bRec, bDict, bSet}

template tua*(v: pointer): ptr UaBytes =
  cast[ptr UaBytes](v)

func refuse*(msg: string) {.noreturn.} =
  raise newException(RefuseError, msg)

template reject*(cond, msg: untyped): untyped =
  if cond:
    refuse msg

# header lens templates
template tag*(b: byte): byte =
  (b and 0xF0) shr 4
template mark*(b: byte): bool =
  (b and 0x08) != 0
template lbits*(b: byte): byte =
  b and 0x07
template kind*(b: byte): Kind =
  Kind(b.tag)
func be32*(a: openArray[byte], i = 0): uint32 {.inline.} =
  (uint32(a[i]) shl 24) or (uint32(a[i+1]) shl 16) or
    (uint32(a[i+2]) shl 8) or uint32(a[i+3])

func cmpBytes*(a, b: openArray[byte]): int =
  let n = min(a.len, b.len)
  if n > 0:
    result = cmpMem(addr a[0], addr b[0], n)
    if result != 0: return
  result = cmp(a.len, b.len)

func validateText*(bytes: openArray[byte]) {.inline.} =
  if not validateUtf8(bytes.toOpenArrayChar(0, bytes.high)):
    refuse "validateText: utf8 not well formed"

func validateInt*(bytes: openArray[byte]) {.inline.} =
  if bytes.len == 0:
    refuse "validateInt: effective length cannot be 0"

  let
    isNegative = (bytes[0] == '-'.byte)
    start = if isNegative: 1 else: 0

  if bytes.len == start:
    refuse("validateInt: effective length cannot be 0")

  if bytes[start] == '0'.byte:
    if bytes.len - start > 1:
      refuse("validateInt: leading zeros are not allowed")
    if isNegative:
      refuse("validateInt: [-0] not a valid int")

  for i in start ..< bytes.len:
    if char(bytes[i]) notin {'0'..'9'}:
      refuse("validateInt: invalid char outside of [0-9]")