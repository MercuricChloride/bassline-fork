import std/options

type
  Tvl* {.pure.} = enum
    ## A 3 valued logic value
    ## unknown / verified true / verified false
    U,T,F

proc `$`*(a: Tvl): string =
  case a
  of U: "unknown"
  of T: "true"
  of F: "false"

template unk*: Tvl = Tvl.U

converter toTvl*(a: bool): Tvl =
  if a: Tvl.T else: Tvl.F

converter toTvl*(a: Option[bool]): Tvl =
  if a.isSome: a.get.toTvl
  else: unk

func n(a: Tvl): int8 =
  case a
  of Tvl.U: 0
  of Tvl.T: 1
  of Tvl.F: -1

func tvl(a: int8): Tvl =
  if a == 0: Tvl.U
  elif a < 0: Tvl.F
  else: Tvl.T

func `and`*(a,b: Tvl): Tvl =
  tvl min(a.n, b.n)

func `or`*(a,b: Tvl): Tvl =
  tvl max(a.n, b.n)

func `not`*(a: Tvl): Tvl =
  tvl a.n * -1

func `xor`*(a,b: Tvl): Tvl =
  tvl a.n * b.n * -1

func `?`*(a: Tvl): Tvl =
  ## unknown?
  a == unk

func known*(a: Tvl): Tvl =
  not ?a

func bool*(a: Tvl): bool =
  a == T