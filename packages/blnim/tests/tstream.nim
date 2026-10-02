## stream: pull-only streams of answers and the combinators over them

import std/[unittest, options]
import bl/ops/stream

proc counted(xs: seq[int], pulls: ref int): Stream[int] =
  ## `xs` as a stream that counts how often it's pulled
  let s = initStream(xs)
  proc(): Option[int] =
    inc pulls[]
    s()

suite "stream":
  test "filter pulls past rejected values":
    check initStream(@[1, 2, 3, 4, 5]).filter(proc(n: int): bool = n mod 2 == 0).toSeq == @[2, 4]
    check initStream(@[1, 3]).filter(proc(n: int): bool = n mod 2 == 0).toSeq.len == 0

  test "|> filters with a predicate and maps otherwise":
    let
      big = proc(n: int): bool = n > 1
      tens = proc(n: int): int = n * 10
    check (initStream(@[1, 2, 3]) |> big |> tens).toSeq == @[20, 30]

  test "take pulls no more than it needs":
    let pulls = new int
    check counted(@[1, 2, 3], pulls).take(0).len == 0
    check pulls[] == 0
    check counted(@[1, 2, 3], pulls).take(2) == @[1, 2]
    check pulls[] == 2
    check initStream(@[1]).take(5) == @[1]

  test "alt takes fair turns until every stream is done":
    check alt(initStream(@[1, 2, 3]), initStream(@[10, 20]), initStream(@[100])).toSeq ==
      @[1, 10, 100, 2, 20, 3]

  test "cat exhausts each stream in order":
    check cat(initStream(@[1, 2]), initStream(newSeq[int]()), initStream(@[3])).toSeq == @[1, 2, 3]

suite "function combinators":
  test "fold runs and scan answers before and after":
    let
      add = proc(a, b: int): int = a + b
      total = fold(add, 0)
      steps = scan(add, 0)
    check total(1) == 1
    check total(2) == 3
    check steps(1) == (prev: 0, curr: 1)
    check steps(2) == (prev: 1, curr: 3)

  test "latch stays false once it fails":
    # typed as `Pred[int]`, `check not small(5)` crashes the 2.2.10 compiler
    # (mapType: tyGenericInvocation), so name the proc type
    let small: proc(n: int): bool = latch(proc(n: int): bool = n < 3)
    check small(1)
    check not small(5)
    check not small(1)
