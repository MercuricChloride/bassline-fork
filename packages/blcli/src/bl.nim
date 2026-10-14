## bl: the bassline toolkit's dispatcher and builtins
##
## `bl NAME args…` runs a builtin, else `bl-NAME`, from beside bl or
## from PATH, in place of this process. One table drives dispatch, help, `which` and
## `commands`, so they can't drift apart.

import std/[os, strutils, terminal]
import harness, banner
import bl_cat, bl_read, bl_send, bl_serve, bl_reach, bl_hash, bl_search, bl_ws, bl_eval, bl_name,
       bl_config

proc builtins(): seq[Tool]

proc builtin(name: string): int =
  ## where `name` is in the table, or -1
  for i, t in builtins():
    if t.name == name:
      return i
  -1

proc runWhich(t: Tool, a: Args) =
  if a.positional.len != 1:
    t.misuse "names exactly one command"
  let name = a.positional[0]
  if builtin(name) >= 0:
    say "builtin " & name & "\n"
    return
  let exe = lookTool("bl-" & name)
  if exe.len == 0:
    fail "no command " & name & " (no builtin, and no bl-" & name &
      " beside bl or on PATH)"
  say exe & "\n"

proc commands(): seq[(string, string)] =
  ## every command here, a line of help each
  for b in builtins():
    result.add (b.name, b.summary)
  for (name, path) in tools("bl-"):
    if name.startsWith("search-"):
      continue # `bl search` lists these
    result.add (name, if builtin(name) >= 0: "(the builtin runs instead)"
                      else: firstHelpLine(path))

proc runCommands(t: Tool, a: Args) =
  if a.positional.len > 0:
    t.misuse "takes no arguments"
  sayRows commands()

let
  whichTool = Tool(name: "which", args: "NAME",
                   summary: "what `bl NAME` would run", run: runWhich)
  scanTool = Tool(name: "scan", args: "[PORT…]",
                  summary: "the places on this machine's networks that answer: bl jam scan",
                  raw: proc(argv: seq[string]) =
                    # the jam's scan, which signs its ask, so it runs where signing is
                    let exe = lookTool("bl-jam")
                    if exe.len == 0:
                      fail "bl scan is bl jam scan, and there is no bl-jam beside bl or on PATH"
                    execTool @[exe, "scan"] & argv)
  commandsTool = Tool(name: "commands",
                      summary: "the builtins and every bl-NAME; " &
                               "`bl search` lists the searches",
                      run: runCommands)

proc builtins(): seq[Tool] =
  @[bl_cat.tool, bl_read.tool, bl_send.tool, bl_serve.tool, bl_reach.tool,
    bl_ws.tool, bl_hash.tool, bl_search.tool, bl_eval.tool, bl_name.tool, bl_config.tool, scanTool, whichTool,
    commandsTool]

proc usage(): string =
  "usage: bl NAME [ARGS…]\n\nthe bassline toolkit\n\n" &
    lined(commands(), indent = "  ")

proc main() =
  let argv = commandLineParams()
  if argv.len == 0 or argv[0] in ["-h", "--help"]:
    # asking what is here is no mistake; a person at a terminal gets the
    # banner too, and a pipe only the usage
    if stdout.isatty: say banner() & "\n"
    say usage()
    return
  let name = argv[0]
  if name.startsWith("-"):
    chatter "bl: unknown option " & name
    toStderr "\n" & usage()
    quit 2
  let i = builtin(name)
  if i >= 0:
    builtins()[i].start(argv[1 .. ^1])
    return
  let exe = lookTool("bl-" & name)
  if exe.len == 0:
    chatter "bl: no command " & name & " (no builtin, and no bl-" & name &
      " beside bl or on PATH)"
    toStderr "\n" & usage()
    quit 2
  execTool @[exe] & argv[1 .. ^1]

when isMainModule:
  main()
