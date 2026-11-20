## Serves the party at the place of `bassline` on port 8455, or at the
## address given. The machine has to hold the place first.

import std/os
import bl/core
import bl/parties/parties

let at = if paramCount() > 0: parseIpAddress(paramStr(1)) else: placeOf(bassline)
discard serve(at)
echo "a party at [", at, "]:", PartyPort
runForever()
