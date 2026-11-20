## Number work, three ways, to see where the time goes. Build it with
## -d:release: the numbers mean nothing otherwise.
##
## - every step a call: a dot product as a function over members, each
##   multiply and add one call to a native, each pull one stream;
## - one call over whole vectors: `!(dot A B)`, its loop in the host;
## - the same call again over the same vectors, read once and kept.
##
## And the cost of one call through the kernel, by fib through rules.
##
##   nim c -r -d:release examples/lang/numeric.nim

import std/[monotimes, times, strutils, strformat]
import bl/lang

template timed(what: string, n: int, body: untyped) =
  let t0 = getMonoTime()
  for _ in 0 ..< n: body
  let ns = (getMonoTime() - t0).inNanoseconds div n
  echo "  ", alignLeft(what, 48), align($ns, 12), " ns"

let cx = base()
cx.numeric

proc vector(n: int): Value =
  var items: seq[Value]
  for i in 0 ..< n: items.add num(i mod 7 - 3)
  initList(items)

# a dot product written as a function over members: each step a call
let stepwise = cx.value(rv"""!(fn dot [xs ys i n acc] [
  !(if [!(lt i! n!)]
    [!(dot! xs! ys! !(add i! 1) n! !(add acc! !(mul !(get xs! i!) !(get ys! i!))))]
    [acc!])])""").get

proc holding(n: int): (Cx, Value, Value) =
  let (a, b) = (vector(n), vector(n))
  let vars = newBDict()
  vars[sym"a"] = a
  vars[sym"b"] = b
  vars[sym"stepwise"] = stepwise
  (cx.within(vars), a, b)

let (held, a, b) = holding(10_000)
let (small, _, _) = holding(500)

let (steps, dot) = (rv"!(stepwise! a! b! 0 500 0)", rv"!(dot a! b!)")

echo "a dot product of two 10 000 member vectors:"
timed "every step a call (500 members, x20 = 10 000)", 1:
  for _ in 0 ..< 20:
    discard small.value(steps)
timed "one call, read anew each time", 20:
  VectorOf.forget
  discard held.value(dot)
timed "one call, read once and kept", 1000:
  discard held.value(dot)
var x = 0
let (ia, ib) = (VectorOf[a], VectorOf[b])
timed "the loop alone, in the host", 1000:
  x = 0
  for i in 0 ..< ia[].len: x += ia[][i] * ib[][i]

echo ""
echo "a call through the kernel, by fib 20 through rules:"
let fibs = cx.within
fibs.install(rules([
  rv"(rule (shape !(fib 0) {}) [0])",
  rv"(rule (shape !(fib 1) {}) [1])",
  rv"(rule (shape !(fib n) {n}) [!(add !(fib !(sub n! 1)) !(fib !(sub n! 2)))])"]))
var calls = 0
proc fib(n: int): int =
  inc calls
  if n < 2: n else: fib(n - 1) + fib(n - 2)
discard fib(20)
let fib20 = rv"!(fib 20)"
let perCall = block:
  let t0 = getMonoTime()
  discard fibs.value(fib20)
  (getMonoTime() - t0).inNanoseconds div calls
echo &"  {calls} fib calls, each with a sub, an add and three rules tried: {perCall} ns a call"
