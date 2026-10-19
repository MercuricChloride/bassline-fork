## Serves a party on [::1] at a port of its own, and prints the port.

import bl/core
import bl/parties/parties

let p = serve(parseIpAddress("::1"), Port(0))
echo p.port
stdout.flushFile
runForever()
