import std/[asyncdispatch, asyncnet]
import tinybl
import tinybl/net

useValue Val

proc client() {.async.} =
  var sock = newAsyncSocket()
  await sock.connect("127.0.0.1", Port(12345))
  echo "connected"
  let s = wrapSocket[Val](sock)
  for i in 1..1:
    s.send bl"(put foo)"
    s.send bl"(get something)"
    s.send bl"(something random)"
  let f = sleepAsync(500)
  f.addCallback(
    proc() = s.close
  )
  s.incoming.listen.onEvent v:
    matchValue v:
    of "(stamped $i $msg)":
      echo "[", i,"] ", msg
    else:
      echo "got a non stamped msg: ", v
  await f
  await s.done

when isMainModule:
  var futs: seq[Future[void]]
  for i in 1..500:
    waitFor sleepAsync(1)
    futs.add client()
  waitFor all(futs)