import pkg/core
import lib/[ops, router, blmacro]

template match(ear, body) =
  accept extract(rv(ear), msg.value, bindings):
    body

when isMainModule:

  router runner:
    var bindings: Value

    accept msg.value == rv"help!":
      msg.reply text"this is a command runner"
    
    match "(cmd! arg!)":
      msg.reply bindings

    match "hello":
      msg.reply text"hello :)"

  proc main() =
    var count = 5000

    proc handler(msg: Msg): bool =
      echo msg.value

    while count < 15_000:
      inc count, 1000
      let 
        a = newMsg(bl print(%count), handler)
        b = newMsg(bl hello, handler)
        c = newMsg(rv"help!", handler)
      runner a
      runner b
      runner c

  main()