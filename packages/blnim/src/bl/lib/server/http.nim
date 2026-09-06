import std/asynchttpserver, asyncdispatch, uri
import ../../core
import ../blmacro

proc toValue(uri: Uri): Value =
  initRec(@[sym"url", text $uri])

proc toValue(req: Request): Value =
  var headers = initSet()
  for k, v in req.headers:
    headers.els.incl initRec(@[sym(k), text(v)])
  initRec(@[
    sym"http-request",
    sym($req.reqMethod),
    toValue(req.url),
    headers,
    text req.body
  ])

proc main {.async.} =
  var server = newAsyncHttpServer()

  proc cb(req: Request) {.async.} =

    echo toValue(req)

    let headers = {"Content-type": "text/plain; charset=utf-8"}
    await req.respond(Http200, "Hello World", headers.newHttpHeaders())

  server.listen(Port(8080))
  let port = server.getPort
  echo "test this with: curl localhost:" & $port.uint16 & "/"
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(cb)
    else:
      await sleepAsync(500)

waitFor main()