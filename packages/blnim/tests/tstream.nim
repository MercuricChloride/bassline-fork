## stream: pull-only streams of answers and the combinators over them

import std/[unittest, options]
import bl/queries

proc counted(xs: seq[int], pulls: ref int): Stream[int] =
  ## `xs` as a stream that counts how often it's pulled
  let s = initStream(xs)
  proc(): Option[int] =
    inc pulls[]
    s()

suite "stream":
  test "filter pulls past rejected values":
    check initStream(@[1, 2, 3, 4, 5]).filter(proc(n: int): bool = n mod 2 == 0).collect == @[2, 4]
    check initStream(@[1, 3]).filter(proc(n: int): bool = n mod 2 == 0).collect.len == 0

  test "|> filters with a predicate and maps otherwise":
    let
      big = proc(n: int): bool = n > 1
      tens = proc(n: int): int = n * 10
    check (initStream(@[1, 2, 3]) |> big |> tens).collect == @[20, 30]

  test "take pulls no more than it needs":
    let pulls = new int
    check counted(@[1, 2, 3], pulls).take(0).len == 0
    check pulls[] == 0
    check counted(@[1, 2, 3], pulls).take(2) == @[1, 2]
    check pulls[] == 2
    check initStream(@[1]).take(5) == @[1]

  test "alt takes fair turns until every stream is done":
    check alt(initStream(@[1, 2, 3]), initStream(@[10, 20]), initStream(@[100])).collect ==
      @[1, 10, 100, 2, 20, 3]

  test "cat exhausts each stream in order":
    check cat(initStream(@[1, 2]), empty[int](), initStream(@[3])).collect == @[1, 2, 3]

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

  test "altFrom takes turns, admitting a stream each round":
    var made = 0
    let supply = proc(): Option[Stream[int]] =
      inc made
      some initStream(@[made * 10, made * 10 + 1])  # an endless supply
    check altFrom(supply).take(5) == @[10, 11, 20, 21, 30]
    let some3 = initStream(@[initStream(@[1, 2, 3]), empty[int](),
                             initStream(@[7])])
    check altFrom(some3).collect == @[1, 2, 3, 7]

  test "merge keeps an order across streams, earlier stream first on a tie":
    let byValue = proc(a, b: int): int = cmp(a, b)
    check merge(byValue, initStream(@[1, 4, 9]), initStream(@[2, 4, 5])).collect ==
      @[1, 2, 4, 4, 5, 9]
    let pulls = new int
    let m = merge(byValue, counted(@[1, 2, 3], pulls), initStream(@[5]))
    check m.take(1) == @[1]
    check pulls[] == 1        # nothing pulled past the answer taken

  test "empty gives nothing":
    check empty[int]()().isNone
    check empty[string]().collect.len == 0

  test "[] is the next pull":
    let s = initStream(@[1, 2])
    check s[] == some 1
    check s[] == some 2
    check s[].isNone
    check empty[int]()[].isNone

  test "k answers the same every time":
    let five = k(5)
    check five() == 5 and five() == 5

  test "just, lazy, catFrom and flatMap":
    check just(7).collect == @[7]
    var made = 0
    let l = lazy(proc(): Stream[int] =
      inc made
      initStream(@[1, 2]))
    check made == 0
    check l.collect == @[1, 2]
    check made == 1
    check catFrom(initStream(@[initStream(@[1]), empty[int](), initStream(@[2, 3])])).collect ==
      @[1, 2, 3]
    check initStream(@[1, 2]).flatMap(proc(n: int): Stream[int] =
      initStream(@[n, n * 10])).collect == @[1, 10, 2, 20]

  test "filterMap, tap, exists and every":
    check initStream(@[1, 2, 3, 4]).filterMap(proc(n: int): Option[int] =
      if n mod 2 == 0: some(n * n) else: none(int)).collect == @[4, 16]
    var seen: seq[int]
    check initStream(@[1, 2]).tap(proc(n: int) = seen.add n).collect == @[1, 2]
    check seen == @[1, 2]
    let pulls = new int
    check counted(@[1, 2, 3], pulls).exists(proc(n: int): bool = n == 2)
    check pulls[] == 2                            # stopped at the first
    check initStream(@[2, 4]).every(proc(n: int): bool = n mod 2 == 0)
    check not initStream(@[2, 3]).every(proc(n: int): bool = n mod 2 == 0)
