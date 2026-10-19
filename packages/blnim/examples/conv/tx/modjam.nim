## The moderated jam: an allow-list, a size cap, muting and the jam, put
## together with `all` and `first`, in every order. A rule that refuses
## after the jam took an answer undoes it, and the jam keeps nothing.

import std/[algorithm, sequtils]
import ./rules

proc run(order: seq[string]): seq[string] =
  transcript = @[]
  let muting = newBSet()
  var rs: seq[Rule]
  for name in order:
    rs.add:
      case name
      of "allow": allow(bl"{ann bob mo}".els)
      of "cap": cap(40)
      of "muted": muted(muting)
      else: first(mute(bl"mo", muting), answers())
  let main = jam(all(rs))
  let (ann, bob, mo, carl) = (person"ann", person"bob", person"mo", person"carl")
  for p in [ann, bob, mo, carl]: p.join main
  ann.says(main, bl"""(general "hi")""")
  carl.says(main, bl"""(general "me too")""")
  bob.says(main, bl"""(general "a much longer answer than that")""")
  bob.says(main, bl"!(mute ann)")
  mo.says(main, bl"!(mute ann)")
  ann.says(main, bl"""(general "hello?")""")
  bob.says(main, bl"""(general "sure")""")
  bob.says(main, bl"(general)")
  bob.says(main, bl"(general 1 2)")
  transcript

echo "== allow, cap, muted, then the jam"
discard run(@["allow", "cap", "muted", "jam"])

quiet = true
var order = @["allow", "cap", "jam", "muted"]
order.sort
var seen: seq[seq[string]]
var orders = 0
while true:
  let t = run(order)
  inc orders
  if t notin seen: seen.add t
  if not order.nextPermutation: break
echo "\n", orders, " orders, ", seen.len, " transcript"
quiet = false
echo "\n== the jam first: carl's answer is taken by the jam, then refused, and nothing is kept"
let t = run(@["jam", "allow", "cap", "muted"])
echo "same as allow first: ", t == run(@["allow", "cap", "muted", "jam"])
