import ../core
import msg, ops
export msg, ops

template router*(body: untyped): Send =
  ##[
  Defines an anonymous send with a fallthrough
  to `defaultRoute`
  
  Used in tandem with `route`
  ]##
  proc(msg {.inject.}: Msg): bool =
    body
    result = defaultRoute(msg)

template router*(name, body: untyped) =
  ##[
  Defines a named send with a fallthrough
  to `defaultRoute`.
  Used in tandem with `route`
  ]##
  let name {.inject.} : Send  = router(body)

template route*(body: untyped) {.dirty.} =
  ##[
    Runs `body` in a named block `currentRoute`
    to allow for defining control flow while
    routing. See `next` / `accept` / `match`
  ]##
  block currentRoute:
    body
    return

template next*() =
  ##[
    Breaks out of the current routing block
    and continues to the next route
  ]## 
  break currentRoute

template accept*(cond) =
  ##[
  skips to the next route unless
  `cond` is true
  ]##
  result = cond
  if not result: next

template accept*(cond, body) =
  ## Shorthand for a route + accept
  route:
    accept(cond)
    body

template match*(ear, body) =
  ##[
    Creates a routing block that binds the
    holes in `ear` from msg.value.
    The bindings are accessible via the injected
    `bindings` variable.
  ]##
  route:
    var bindings {.inject.} = initDict()
    accept extract(ear, msg.value, bindings)
    body

when isMainModule:
  import ./blmacro

  let
    help = rv"help!"
    cmdShape = rv"(cmd! arg!)"
    hello = rv"hello"
    ping = rv"ping"
    pong = rv"pong"
    what = rv"what"

  router pingPong:
    accept msg.value == ping:
      msg.reply pong
    accept msg.value == pong:
      msg.reply what

  proc handler(msg: Msg): bool =
    echo msg.value

  proc doPing() =
    var count: int
    while count < 5:
      inc count
      if count mod 100 == 0:
        echo count
      let m = newMsg(ping, handler, 1)
      pingPong.send m.fork
      pingPong.send m
      pingPong.send pong

  router runner:
    accept msg.value == help:
      msg.reply text"this is a command runner"

    accept msg.value == hello:
      msg.reply text"hello :)"

    match cmdShape:
      msg.reply bindings

  proc doRunner() =
    var count = 1000
    while count < 15_000:
      inc count, 1000
      let 
        a = newMsg(bl print(%count), handler)
        b = newMsg(bl hello, handler)
        c = newMsg(rv"help!", handler)
      discard runner a
      discard runner b
      discard runner c

  proc main() =
    doPing()
    doRunner()

  main()