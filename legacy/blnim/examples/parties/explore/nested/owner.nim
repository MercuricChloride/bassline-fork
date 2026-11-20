## Hosts a party inside TOPIC at the party at HOST PORT, and a bridge to
## it on [::1] at a port of its own, which it prints:
##
##   owner HOST PORT TOPIC

import std/[os, strutils]
import bl/core
import ./nest

if paramCount() < 3: quit "owner HOST PORT TOPIC"
let
  (at, port) = (parseIpAddress(paramStr(1)), Port(paramStr(2).parseInt))
  topic = readValue(paramStr(3))
discard host(at, port, topic)
echo bridge(at, port, topic)
stdout.flushFile
runForever()
