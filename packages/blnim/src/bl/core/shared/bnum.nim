import std/[strutils, options]
import bigints
import ./shared

refuseWith BasslineError

type
  BNum* = object
    case isBig*: bool
    of false:
      small*: int
    of true:
      big*: BigInt

func initNum*(n: BigInt): BNum = 
  BNum(isBig: true, big: n)

func initNum*(n: SomeInteger): BNum = 
  BNum(isBig: false, small: n.int)

func initNum*(s: string): BNum =
  ## s is a canonical spelling; past int64 it is held as it is spelled
  guard isValidInt(s.toBytes), "not a canonical number: " & s
  try:
    BNum(isBig: false, small: parseBiggestInt(s))
  except ValueError:
    BNum(isBig: true, big: initBigInt(s, 10))

converter toNum*(n: SomeInteger): BNum =
  initNum(n)

converter toNum*(n: BigInt): BNum =
  initNum(n)

func `'num`*(s: string): BNum = 
  initNum(s)

func isBig*(n: BNum): bool = n.isBig

func grow*(n: BNum): BNum =
  if n.isBig: n
  else: initNum(initBigInt(n.small))

func isInt*(n: BNum): bool = not n.isBig

func toInt*(n: BNum): int =
  if n.isBig:
    let x = toInt[int](n.big)
    guard x.isSome, "num is wide, not an int"
    x.get
  else:
    n.small

func toString*(n: BNum): string =
  if n.isBig: $n.big else: $n.small

func `$`*(n: BNum): string =
  n.toString

template lift(a, b, op): untyped =
  if a.isBig and b.isBig:
    return op(a.big, b.big)
  elif a.isBig:
    return op(a.big, initBigInt(b.small))
  elif b.isBig:
    return op(initBigInt(a.small), b.big)
  else:
    return op(a.small, b.small)

template binary(op, T) =
  func op*(a, b: BNum): T =
    when T is BNum:
      try:
        lift(a, b, op)
      except OverflowDefect:
        let 
          x = a.grow
          y = b.grow
        lift(x, y, op)
    else:
      lift(a, b, op)

binary `+`, BNum
binary `-`, BNum
binary `*`, BNum
binary `div`, BNum
binary `mod`, BNum

binary `cmp`, int
binary `<`, bool
binary `<=`, bool
binary `==`, bool

func inc*(n: var BNum, by = 1) =
  n = n + by

func dec*(n: var BNum, by = 1) =
  n = n - by

func pow*(x: BNum, power: Natural): BNum =
  x.grow.big.pow(power)

func powmod*(x: BNum, power: int, modulus: Natural): BNum =
  x.grow.big.powmod(power, modulus)

iterator `..`*(a, b: BNum): BNum =
  ## Counts from `a` up to `b` (inclusive).
  var res = a
  while res <= b:
    yield res
    inc res

iterator `..<`*(a, b: BNum): BNum =
  ## Counts from `a` up to `b` (exclusive).
  var res = a
  while res < b:
    yield res
    inc res

func magnitude*(x: int): uint64 =
  ## |x| without the abs(int.low) overflow
  if x < 0: uint64(-(x + 1)) + 1
  else: uint64(x)

func abs*(n: BNum): BNum =
  if n.isBig: 
    initNum(n.big.abs)
  else:
    let x = n.small
    if x < 0: initNum(x.magnitude)
    else: n

func spellingLen*(n: BNum): int =
  ## how many characters $n would take up
  if n < 0'num: 
    inc result
  if n.isBig:
    # NOTE: bigints does a fast estimation for the size of the string here
    # so I will replace this later
    return len($n.big)
  else:
    let x = n.small
    var m = magnitude x
    result = if x < 0: 2 else: 1
    while m >= 10:
      inc result
      m = m div 10

func cmpInts*(x, y: int): int =
  ## ascii shortlex over the decimal strings
  ## without making them strings
  result = cmp(spellingLen(x), spellingLen(y))
  if result != 0: return
  let nx = x < 0
  let ny = y < 0
  if nx != ny:
    return if nx: -1 else: 1
  result = cmp(magnitude(x), magnitude(y))

func cmpNums*(x, y: BNum): int =
  if x.isBig or y.isBig:
    cmpShortlex(x.toString.toBytes, y.toString.toBytes)
  else:
    cmpInts(x.toInt, y.toInt)