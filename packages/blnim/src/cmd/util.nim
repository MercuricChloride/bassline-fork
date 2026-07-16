import std/[strutils, nativesockets]

proc parsePort*(s: string; allowZero = false): Port =
  ## Port(x) wraps modulo 2^16 on out-of-range ints, so the range
  ## check has to happen here.
  var port: int
  try:
    port = parseInt(s)
  except ValueError:
    quit "port must be a number, got: " & s
  let lo = if allowZero: 0 else: 1
  if port < lo or port > 65535:
    quit "port out of range (" & $lo & "-65535): " & s
  Port(port)
