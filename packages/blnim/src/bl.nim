import std/parseopt
import cmd/[serve, file, send]

proc printHelp() =
  echo """
bl -- bassline cli

Usage:
  bl serve [--port:N] [--address:H] [--echo]
                                 land values from TCP and print them
  bl file <path>                 write a file or directory to stdout
                                 as a value
  bl send <dest>                 send values from stdin to a landing
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
      of "serve":
        serve.run(p.remainingArgs())
        return
      of "file":
        file.run(p.remainingArgs())
        return
      of "send":
        send.run(p.remainingArgs())
        return
      else:
        echo "unknown command: ", p.key
        printHelp()
        quit 1

  printHelp()

when isMainModule:
  main()
