import ../ops
import ./msg
export msg, ops

template router*(body: untyped): Send =
  ##[
  Defines an anonymous send
  Used in tandem with `route`
  ]##
  proc(msg {.inject.}: Msg): bool =
    body

template router*(name, body: untyped) =
  ##[
  Defines a named send.
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

template matchShape*(shape: Shape, body) =
  ##[
    Creates a routing block that matches msg.value
    to the shape provided.
    The bindings are accessible via the injected
    `bindings` variable.
  ]##
  route:
    shape.withMatch:
      match += msg.value
      var bindings {.inject.} = match.bindings
      accept match.isFilled
      body

when isMainModule:
  import ../core
  import ../lib/blmacro
  import std/strformat

  let
    help = rv"help!"
    cmdShape = rv"(shape (cmd! args) {cmd! args})"
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

    matchShape toShape(cmdShape):
      msg.reply bindings.toValue

  proc doRunner() =
    var count = 1000

    while count < 15_000:
      inc count, 1000
      runner.send newMsg(rv fmt"(print! {count})", handler)
      runner.send newMsg(help, handler)
      runner.send newMsg(hello, handler)

  proc main() =
    doPing()
    doRunner()

  main()