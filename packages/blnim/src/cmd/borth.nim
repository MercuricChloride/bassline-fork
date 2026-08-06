import pkg/lib/[borth, reader]
import ./util

const help = """
A stack language built on bassline.

Usage:
  bl borth [file ...]     run documents; with no files, run stdin
                          as a live value stream
"""

const DefaultTick = 100

const Prelude = staticRead("../lib/borth/prelude.bl")

proc frameLine(f: Frame): string =
  case f.kind
  of fCode: "code @" & $f.ip & "/" & $f.body.len
  of fExpand: "expansion @" & $f.ip & "/" & $f.body.len
  of fPush: "restore " & $f.saved
  of fEach: "each @" & $f.idx & " over a " & $f.src.kind
  of fMap: "map @" & $f.idx & " over a " & $f.src.kind

proc run*(args: seq[string]) =
  var runtime = initRuntime()
  installCore(runtime)

  var paths: seq[string]

  for kind, key, val in cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      else:
        quit "unknown borth option: " & key & "\n\n" & help
    else:
      paths.add key

  proc feed(v: Value) =
    runtime.feedValue(v)

  proc run() =
    try:
      runtime.run()
    except RuntimeError as e:
      var msg = "RUNTIME ERROR\n"
      msg &= e.msg
      msg &= "\nSTACK:\n["
      for i, v in runtime.stack:
        msg &= $i & ": " & $v & "\n"
      msg &= "]\n"
      msg &= "FRAMES:\n["
      for i in countdown(runtime.frames.high, 0):
        msg &= $i & ": " & frameLine(runtime.frames[i]) & "\n"
      msg &= "]\n"
      msg &= "INPUT:\n["
      for i, v in runtime.input:
        msg &= $i & ": " & $v & "\n"
      msg &= "]\n"
      stderr.write(msg)
      quit(1)

  proc doEmit(rt: var Runtime) =
    emit rt.pop()

  runtime.undef("echo", force = true)
  runtime.primitive "echo", doEmit

  runtime.feedValue readDocument(Prelude)
  run()

  if paths.len == 0:
    eachValueTicking(stdin, feed, DefaultTick, run)
  else:
    for path in paths:
      runtime.feedValue readDocument(readFile(path))
    run()
