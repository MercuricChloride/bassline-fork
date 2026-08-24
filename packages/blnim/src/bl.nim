import std/[parseopt, os, posix, strutils]
import
  cmd/[
    listen, file,  send, hash, cat, keygen, sign, verify, put, get, read,
    reach,
    #assemble
  ]

const Builtins = [
  "listen", "file", "send", "hash", "cat", "keygen", "sign", "verify", "put",
  "get", "read", "reach", "which", "commands",
]

proc printHelp() =
  echo """
bl -- bassline cli

Usage:
  bl listen [on] [--echo]        open a landing for values to stdout
  bl file <path>                 write a file or directory to stdout
                                 as chunks and manifests
  bl assemble --into <path>      put a chunked tree back
  bl send [dest]                 send values from stdin to a landing
  bl hash                        name each stdin value by content
  bl cat [file ...]              print values as text
  bl read [file ...]             read text values, write canonical bytes
  bl keygen [--out:PATH]         generate a keypair value
  bl sign [--key:PATH]           wrap each stdin value with attestation
  bl verify                      check signed values, emit the inner
  bl put [--store:PATH]          hold stdin values, emit their names
  bl get [--store:PATH]          resolve digest names to content
  bl reach PLACE [-- CMD ...]    give stdin/stdout, or a command's, to a place
  bl which NAME                  say what would run for a command name
  bl commands                    list builtin and PATH commands
  bl <command> --help            command-specific help
  bl -h | --help
  bl -v | --version

Any other NAME runs bl-NAME from PATH, so commands can be added
without touching bl.
"""

proc runWhich(args: seq[string]) =
  if args.len != 1:
    quit "which takes exactly one command name"
  let name = args[0]
  if name in Builtins:
    echo "builtin " & name
    return
  let exe = findExe("bl-" & name)
  if exe.len > 0:
    echo exe
  else:
    quit "no command " & name, 1

proc runCommands() =
  for b in Builtins:
    echo b & "\tbuiltin"
  for dir in getEnv("PATH").split(PathSep):
    if dir.len == 0 or not dirExists(dir):
      continue
    for kind, path in walkDir(dir):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      let base = path.extractFilename
      if base.len > 3 and base.startsWith("bl-") and
          fpUserExec in getFilePermissions(path):
        echo base[3 .. ^1] & "\t" & path

proc runExternal(name: string, args: seq[string]) =
  ## PATH is the extension mechanism: bl-NAME runs as bl NAME. The
  ## exec preserves stdio, exit status, and signal behavior.
  let exe = findExe("bl-" & name)
  if exe.len == 0:
    echo "unknown command: ", name
    printHelp()
    quit 1
  var argv = @[exe] & args
  let cargs = allocCStringArray(argv)
  discard execv(exe.cstring, cargs)
  quit "cannot exec " & exe & ": " & $strerror(errno)

proc main() =
  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        printHelp()
        return
      of "v", "version":
        echo "bl 0.1.0"
        return
      else:
        echo "unknown option: ", p.key
        printHelp()
        quit 1
    of cmdArgument:
      case p.key
      of "listen":
        listen.run(p.remainingArgs())
        return
      of "file":
        file.run(p.remainingArgs())
        return
      # of "assemble":
      #   assemble.run(p.remainingArgs())
      #   return
      of "send":
        send.run(p.remainingArgs())
        return
      of "hash":
        hash.run(p.remainingArgs())
        return
      of "cat":
        cat.run(p.remainingArgs())
        return
      of "read":
        read.run(p.remainingArgs())
        return
      of "keygen":
        keygen.run(p.remainingArgs())
        return
      of "sign":
        sign.run(p.remainingArgs())
        return
      of "verify":
        verify.run(p.remainingArgs())
        return
      of "put":
        put.run(p.remainingArgs())
        return
      of "get":
        get.run(p.remainingArgs())
        return
      of "reach":
        reach.run(p.remainingArgs())
        return
      of "which":
        runWhich(p.remainingArgs())
        return
      of "commands":
        runCommands()
        return
      else:
        runExternal(p.key, p.remainingArgs())
        return

  printHelp()

when isMainModule:
  main()
