import std/[os, sysrand]
import pkg/core
import pkg/lib/reader
import pkg/lib/crypto/clave
import ./util

const help = """
bl keygen [--out:PATH] [--force]

Don't send this around as a value!

Generates a keypair and writes it as a value,
(keypair eddsa-blake2b 0x<seed> 0x<public>), mode 600.
Default path: ~/.bl/key.blb
"""

proc defaultKeyPath*(): string =
  blHome() / "key.blb"

proc run*(args: seq[string]) =
  var
    outPath = defaultKeyPath()
    force = false
  for kind, key, val in cmdOpts(
    args, shortNoVal = {'h'}, longNoVal = @["help", "force"]
  ):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "out":
        if val == "":
          quit "--out needs a path"
        outPath = val
      of "force":
        force = true
      else:
        quit "unknown keygen option: " & key & "\n\n" & help
    else:
      quit "keygen takes no arguments\n\n" & help

  if fileExists(outPath) and not force:
    quit outPath & " already exists (--force to overwrite)"

  let rnd = urandom(32)
  var seed: Seed
  copyMem(addr seed[0], addr rnd[0], 32)
  let kp = keypairFromSeed(seed)

  createDir(outPath.parentDir)
  writeFile(outPath, encode(kp.toValue))
  setFilePermissions(outPath, {fpUserRead, fpUserWrite})
  stderr.writeLine "-- wrote " & outPath
  stderr.writeLine "-- public " & $bytes(@(kp.public))
