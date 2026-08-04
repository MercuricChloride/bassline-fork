include pkg/prelude
import std/parseopt
import
  cmd/[
    listen, file,  send, hash, cat, keygen, sign, verify, put, get, read,
    borth,
    #assemble
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
  bl borth [file ...]            run borth documents, or stdin live
  bl <command> --help            command-specific help
  bl -h | --help
  bl -v | --version
"""

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
      of "borth":
        borth.run(p.remainingArgs())
        return
      else:
        echo "unknown command: ", p.key
        printHelp()
        quit 1

  printHelp()

when isMainModule:
  main()
