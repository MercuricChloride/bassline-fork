import std/strutils
import bigints
import ./ce

refuseWith BasslineError

type
  Live* = ref object of RootObj
  Node* = object
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
      vseq*: seq[Value]
  Value* = object
    case
    of Data:
      data*: Node
    of Bound:
      live*: Live
  ValueBuilder* = object

method reify*(self: Live): Node {.base, raises: [BasslineError].} =
  refuse "reify must be implemented!"

using
  mark: bool
  kind: Kind

const BuildValue* = ValueBuilder()

func initNum(n: BigInt, mark): Value =
  Data(data: Big(kind: bNum, mark: mark, vbig: n))

func initNum(n: SomeInteger, mark): Value =
  when n is uint64 or n is uint:
    if n > uint64(high(int)):
      return initNum(initBigInt(uint64(n)), mark)
  Data(data: Int(kind: bNum, mark: mark, vint: n.int))

func initNum(s: string, mark): Value =
  guard isValidInt(s), "not a canonical number: " & s
  try:
    initNum(s.parseBiggestInt, mark)
  except ValueError:
    try:
      initNum(initBigInt(s, 10), mark)
    except ValueError:
      refuse("not a number: " & s)

proc null*(_: ValueBuilder, mark): Value =
  Data(data: Null(kind: bNil, mark: mark))

proc atom*(_: ValueBuilder, s: sink string, kind, mark): Value =
  let k: bNum .. bBytes = kind
  case k
  of bNum:
    initNum(s, mark)
  else:
    Data(data: Str(kind: k, mark: mark, vstr: s))

proc frame*(_: ValueBuilder, s: sink seq[Value], kind, mark): Value =
  Data(data: Seq(kind: kind, mark: mark, vseq: s))

when isMainModule:
  import std/[monotimes, times]

  # the jam, whole, through both types
  let 
    jam = readFile("/Users/goose/prg/jordans-bl/jams/jam.blb").repeat(50)
    size = jam.len / 1_000_000

  proc decode(label: string) =
    var best = float.high
    for _ in 0..<7:
      var
        pos = 0
        reader = initReader(BuildValue)
      let t0 = getMonoTime()
      for _ in reader.readEach(jam):
        discard
      best = min(best, (getMonoTime() - t0).inNanoseconds.float / 1e6)
    echo label, ": ", best, " ms"
  decode("decode value " & $size & "MB")