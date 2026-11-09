import std/strutils
import bigints
import ./ce

refuseWith BasslineError

type
  RawValue* {.byref.} = object
    mark*: bool
    kind*: Kind
    case
    of Null: discard
    of Str:
      vstr*: string
    of Int:
      vint*: int
    of Big:
      vbig*: BigInt
    of Seq:
      vseq*: seq[RawValue]
  RawBuilder* = object

using
  mark: bool
  kind: Kind

const BuildRaw* = RawBuilder()

func len*(self: RawValue): int =
  case self
  of Seq(s): s.len
  else: 0

func initNum(n: BigInt, mark): RawValue =
  Big(kind: bNum, mark: mark, vbig: n)

func initNum(n: SomeInteger, mark): RawValue =
  when n is uint64 or n is uint:
    if n > uint64(high(int)):
      return initNum(initBigInt(uint64(n)), mark)
  Int(kind: bNum, mark: mark, vint: n.int)

func initNum(s: string, mark): RawValue =
  guard isValidInt(s), "not a canonical number: " & s
  try:
    initNum(s.parseBiggestInt, mark)
  except ValueError:
    try:
      initNum(initBigInt(s, 10), mark)
    except ValueError:
      refuse("not a number: " & s)

proc null*(_: RawBuilder, mark): RawValue =
  Null(kind: bNil, mark: mark)

proc atom*(_: RawBuilder, s: sink string, kind, mark): RawValue =
  let k: bNum .. bBytes = kind
  case k
  of bNum:
    initNum(s, mark)
  else:
    Str(kind: k, mark: mark, vstr: s)

proc frame*(_: RawBuilder, s: sink seq[RawValue], kind, mark): RawValue =
  Seq(kind: kind, mark: mark, vseq: s)

when isMainModule:
  import std/[monotimes, times, os, strutils]

  # the jam, whole, through both types
  let 
    jam = readFile("/Users/goose/prg/jordans-bl/jams/jam.blb").repeat(50)
    size = jam.len / 1_000_000

  proc decode(label: string) =
    var best = float.high
    for _ in 0..<7:
      var
        pos = 0
        reader = initReader(BuildRaw)
      let t0 = getMonoTime()
      for _ in reader.readEach(jam):
        discard
      best = min(best, (getMonoTime() - t0).inNanoseconds.float / 1e6)
    echo label, ": ", best, " ms"
  decode("decode raw " & $size & "MB")