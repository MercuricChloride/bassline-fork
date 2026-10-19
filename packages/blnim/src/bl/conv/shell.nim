##[
  A shell: a participant that does the commands it hears, so a program
  is put together from values. A command is a marked value, and what
  isn't one the shell leaves alone.

  The shell keeps values by name: `!(set NAME VALUE)` keeps one, and
  `!(get NAME)` says (NAME VALUE) into the room it was asked in.
  `!(def NAME [COMMAND …])` keeps a command made of commands, under
  (def NAME!), and `NAME!` does each of them in turn. A program adds
  its own commands with `command`. One that fails is said back as
  (failed COMMAND WHY), and one nobody knows as (unknown COMMAND).
  `!(say VALUE)` says VALUE, so a command can be put to whoever else
  is in the room without the shell doing it.

  By default it knows `!(log)` and `!(quiet)`, to print what it hears
  and says or not, `!(serve-tcp PORT)`, `!(connect-tcp HOST PORT)`,
  `!(input ce)` or `!(input text)` and `!(output ce)` or `!(output text)`
  to put stdin and stdout in the room, `!(wait MS)` and `!(exit)`.

  Anyone in a room the shell is in can have it do anything it knows,
  over a wire as readily as here.
]##
import std/[cmdline, strutils, os, osproc]
import ../core
import ./[conv, stdio, tcp]

type
  Command* = proc(sh: Shell, msg: Msg): bool
    ## does `msg` if it is this command, answering whether it was

  Shell* = ref object of Speaker
    commands: seq[Command]
    kept: BDict                    ## values by name
    logging: bool
    pending: seq[Future[void]]     ## what commands began, for `run` to wait on
    done*: Future[void]            ## complete once told !(exit)

template command*(shell: Shell, pattern: string, body: untyped) =
  ## adds the command a value fitting `pattern` is, as matchValue reads
  ## it, with `sh`, `msg` and `room` bound in `body`
  shell.commands.add proc(sh {.inject.}: Shell, msg {.inject.}: Msg): bool =
    let room {.inject.} = msg.room
    matchValue msg.value:
    of pattern:
      body
      true
    else: false

proc `[]`*(sh: Shell, name: Value): Value =
  ## what `sh` keeps as `name`, or nil
  if name in sh.kept: sh.kept[name] else: null()

proc says*(sh: Shell, room: Room, v: Value) =
  ## `sh` says `v` into `room`, printing it first if it is logging
  if sh.logging: echo "> ", v
  discard sh.say(room, v)

proc fail(sh: Shell, msg: Msg, why: string) =
  let (cmd, why) = (msg.value, text(why.splitLines[0]))  # not an async traceback
  sh.says(msg.room, bl"(failed $cmd $why)")

proc doing*(sh: Shell, msg: Msg) =
  ## does the command `msg` is, if `sh` knows it
  try:
    for c in sh.commands:
      if c(sh, msg): return
    matchValue msg.value:
    of "$name!":
      let made = sh[name]
      if made.isKind(bList):
        for each in made.items.data: sh.doing Msg(room: msg.room, by: msg.by, value: each)
        return
    else: discard
    let cmd = msg.value
    sh.says(msg.room, bl"(unknown $cmd)")
  except CatchableError as e:
    sh.fail(msg, e.msg)

method send*(sh: Shell, msg: Msg) =
  if sh.logging: echo msg.value
  if msg.value.mark: sh.doing msg

proc dialling(sh: Shell, msg: Msg, host: string, port: Port) {.async.} =
  try: discard await dial(host, port, msg.room)
  except CatchableError as e: sh.fail(msg, e.msg)

proc runCmd(cmd: Value, args: Value): string =
  cmd.expectKind({bText}, unmarked)
  args.expectKind({bList, bText, bNil}, unmarked)
  var strArgs: seq[string]
  case args.kind:
  of bList:
    for arg in args.items:
      arg.expectKind({bText}, unmarked)
      strArgs.add arg.text
  of bText:
    strArgs.add args.text
  else: discard
  execProcess(cmd.text, args=strArgs, options={poUsePath})

proc newShell*(): Shell =
  ## a shell knowing the default commands
  result = Shell(kept: newBDict(), done: newFuture[void]("shell"))
  let shell = result
  shell.command "!(set $name $v)": sh.kept[name] = v
  shell.command "!(get $name)":
    let v = sh[name]
    sh.says(room, bl"($name $v)")
  shell.command "!(say $v)": sh.says(room, v)
  shell.command "!(def $name $commands)": sh.kept[bl"$name!"] = commands
  shell.command "!(log)": sh.logging = true
  shell.command "!(quiet)": sh.logging = false
  shell.command "!(serve-tcp $port)": discard listen(Port(port.num.toInt), room)
  shell.command "!(connect-tcp $host $port)":
    sh.pending.add sh.dialling(msg, host.text, Port(port.num.toInt))
  shell.command "!(input ce)": input.join room
  shell.command "!(input text)":
    input.asText = true
    input.join room
  shell.command "!(output ce)": output.join room
  shell.command "!(output text)":
    output.asText = true
    output.join room
  shell.command "!(wait $ms)": sh.pending.add sleepAsync(ms.num.toInt)
  shell.command "!(exit)":
    if not sh.done.finished: sh.done.complete

  shell.command "!(run $cmd)":
    let res = runCmd(cmd, null())
    sh.say(room, bl"(result $res)")
  shell.command "!(run $cmd $args)":
    let res = runCmd(cmd, args)
    sh.say(room, bl"(result $res)")

  shell.command "!{from: $lo to: $hi}":
    var list = initList()
    for i in lo.num.toInt..hi.num.toInt:
      list.add num(i)
    sh.says(room, list)

proc run*(sh: Shell, room: Room, values: seq[Value]) {.async.} =
  ## does each of `values` in turn in `room`, or says it there when it
  ## isn't a command, waiting for whatever a command began before the
  ## next
  for v in values:
    if v.mark: sh.doing Msg(room: room, value: v)
    else: sh.says(room, v)
    while sh.pending.len > 0:
      await sh.pending.pop

when isMainModule:
  proc main() {.async.} =
    let (root, sh) = (Conversation(), newShell())
    sh.join root
    await sh.run(root, readDocument(readFile(commandLineParams()[0])))
    await sh.done

  let running = main()
  while not running.finished and hasPendingOperations():  # until !(exit), or nothing is left to do
    poll()
  if running.failed: raise running.readError
