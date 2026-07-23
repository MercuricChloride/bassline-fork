import std/os
import ../lib/[common, clave]
import util
import keygen

const help = """
bl sign [--key:PATH]

Wraps values from stdin with its attestation:
(signed <value> (signature eddsa-blake2b #[sig] #[public])).
The signature is of the value's canonical bytes so checking it
needs nothing beyond the signed value itself.
Default key: ~/.bl/key.blb (bl keygen)
"""

proc loadKeypair(path: string): Keypair =
  if not fileExists(path):
    quit "no key at " & path & " (run bl keygen)"
  let v =
    try:
      decode(readFile(path))
    except DecodeError as e:
      quit path & " isn't a value: " & e.msg
  let kp = fromValue(v, Keypair)
  if kp.isNone:
    quit path & " doesn't hold a (keypair " & Scheme & " ...) value"
  kp.get

proc run*(args: seq[string]) =
  var keyPath = defaultKeyPath()
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "key":
        if val == "":
          quit "--key needs a path"
        keyPath = val
      else:
        quit "unknown sign option: " & key & "\n\n" & help
    else:
      quit "sign takes no arguments\n\n" & help

  let kp = loadKeypair(keyPath)
  runFilter(
    proc(v: Value): Option[Value] =
      some signedValue(kp, v)
  )
