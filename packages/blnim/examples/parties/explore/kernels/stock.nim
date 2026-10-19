## The stock party, bl/parties/parties.nim, served on [::1] at a port
## of its own.
import bl/core
import bl/parties/parties

let p = serve(parseIpAddress("::1"), Port(0))
echo "[::1]:", p.port.int, " ", p.name
stdout.flushFile
runForever()
