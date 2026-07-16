import std/[parseopt]

# This is a stub for now!

proc printHelp() =
  echo """
bl cli
Options:
  -h, --help          Show this help message
  -v, --version       Show version info
  -g, --greet:<name>  Greet a specific user
"""

proc main() =
  var filename = ""
  var greetName = ""

  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        printHelp()
        return
      of "v", "version":
        echo "v1.0"
        return
      of "g", "greet":
        greetName = p.val
      else:
        echo "Unknown option: ", p.key
        return
    of cmdArgument:
      filename = p.key

  if filename == "":
    echo "Error: Missing required filename argument."
    printHelp()
  else:
    if greetName != "":
      echo "Hello, ", greetName, "!"
    echo "Processing file: ", filename

when isMainModule:
  main()