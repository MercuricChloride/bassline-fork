## A party on [::1] at a port the system picks, for the jam prototype.
## It prints the port and serves until it is stopped.

import bl/parties/parties

let p = serve(parseIpAddress("::1"), Port(0))
echo p.port.int
stdout.flushFile
runForever()
