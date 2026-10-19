## the bl tools at the edge: send and serve, names and the config, and reach

import cli

suite "send and serve":
  test "send into serve over TCP delivers every value byte for byte":
    let s = serve(":0")
    let r = sh("bl send " & s.place, corpus)
    check r.code == 0
    check r.errors == "-- sent " & $corpusCount & " value(s) to " & s.place & "\n"
    check s.arrived(corpus.len) == corpus
    let chatter = s.stop
    check "-- open 127.0.0.1:" in chatter
    check "-- close 127.0.0.1:" in chatter

  test "send reaches serve by every TCP spelling, one connection each":
    let s = serve("127.0.0.1:0")
    var want: string
    for (spelled, host, said) in [("tcp://127.0.0.1:", "127.0.0.1", "(tcp)"),
                                  ("127.0.0.1:", "127.0.0.1", "(hostport)"),
                                  ("localhost:", "localhost", "(named)"),
                                  (":", "127.0.0.1", "(colon)"),
                                  ("", "127.0.0.1", "(bare)")]:
      let r = sh("bl send " & spelled & s.port, blb(said))
      check r.code == 0
      check r.errors == "-- sent 1 value(s) to " & host & ":" & s.port & "\n"
      want.add blb(said)
    check s.arrived(want.len) == want
    check s.stop.count("-- open ") == 5

  test "a name is the place it names, the first of several that takes a connection":
    let homed = "HOME=" & quoteShell(tmp / "names-home") & " "
    let s = serve("127.0.0.1:0")
    # nothing answers at the first, so the second is the place
    check sh(homed & "bl name here 10.255.255.1:1 " & s.place).code == 0
    check sh(homed & "bl name | bl cat").output ==
      "((place here) \"10.255.255.1:1\")\n((place here) \"" & s.place & "\")\n"
    let r = sh(homed & "bl send here", blb("(by-name)"))
    check r.code == 0 and r.errors == "-- sent 1 value(s) to " & s.place & "\n"
    check s.arrived(blb("(by-name)").len) == blb("(by-name)")
    check sh(homed & "bl name there here").code == 2       # a name names places, not names
    check sh(homed & "bl name 9lives :1").code == 2         # not a name
    check sh(homed & "bl name there ssh://far").code == 2   # TCP places only
    check sh(homed & "bl name --forget here").code == 0
    check sh(homed & "bl name").output == ""
    let gone = sh(homed & "bl send here", blb("(x)"))   # now the party at the place of here
    check gone.code != 0 and "can't reach [fd" in gone.errors
    discard s.stop

  test "the config answers what a tool isn't told, and a tool's own word comes first":
    let homed = "HOME=" & quoteShell(tmp / "config-home") & " "
    let s = serve("127.0.0.1:0")
    check sh(homed & "bl config send " & s.place).code == 0
    check sh(homed & "bl send", blb("(configured)")).code == 0
    check s.arrived(blb("(configured)").len) == blb("(configured)")
    check sh(homed & "bl config send | bl cat").output == "(send \"" & s.place & "\")\n"
    let other = serve("127.0.0.1:0")
    check sh(homed & "bl send " & other.place, blb("(said)")).code == 0   # the place given wins
    check other.arrived(blb("(said)").len) == blb("(said)")
    discard other.stop
    check sh(homed & "bl config at nowhere:x").code == 2     # not a place, nor a name
    check sh(homed & "bl config --add '(note)' one && " & homed & "bl config --add '(note)' two").code == 0
    check sh(homed & "bl config '(note)' | bl cat").output == "((note) one)\n((note) two)\n"
    check sh(homed & "bl config --forget '(note)' one").code == 0
    check sh(homed & "bl config | bl cat").output ==
      "(send \"" & s.place & "\")\n((note) two)\n"
    check sh(homed & "bl config --forget '(note)' one").code == 1
    discard s.stop

  test "with no place, serve listens on every interface and send meets it at 127.0.0.1:8455":
    let p = startProcess(bin / "bl", args = ["serve"], options = {})
    let said = p.errorStream.readLine
    if said != "-- listening on 0.0.0.0:8455":
      skip()
      discard kill(Pid(p.processID), SIGTERM)
    else:
      check sh("bl send", blb("(hello)")).code == 0
      check readFor(cint(p.outputHandle), 8) == blb("(hello)")
      # ssh://host alone reaches the far side's default place
      let r = sh("bl send ssh://far", blb("(far)"))
      check r.code == 0
      check r.errors == "-- sent 1 value(s) to ssh://far/127.0.0.1:8455\n"
      check readFor(cint(p.outputHandle), 6) == blb("(far)")
      discard kill(Pid(p.processID), SIGTERM)
    discard p.waitForExit
    p.close

  test "serve says when the other end stops partway through a value":
    let s = serve(":0")
    check sh("bl reach --source " & s.place, blb("(a b)")[0 .. ^2]).code == 0
    check sh("bl reach --source " & s.place, "\x00").code == 0
    check sh("bl send " & s.place, blb("(after)")).code == 0
    check s.arrived(blb("(after)").len) == blb("(after)")
    let chatter = s.stop
    check "-- truncated 127.0.0.1:" in chatter
    check "-- malformed 127.0.0.1:" in chatter

  test "--max-value drops a connection that sends something bigger":
    let s = serve(":0", @["--max-value", "16"])
    check sh("bl send " & s.place, blb("\"" & "x".repeat(40) & "\"")).code == 0
    check sh("bl send " & s.place, blb("small")).code == 0
    check s.arrived(blb("small").len) == blb("small")
    check "past --max-value 16" in s.stop

  test "send over ssh:// runs bl reach on the far side":
    let s = serve(":0")
    let r = sh("bl send ssh://far/:" & s.port, corpus)
    check r.code == 0
    check r.errors == "-- sent " & $corpusCount & " value(s) to ssh://far/" &
                      s.place & "\n"
    check s.arrived(corpus.len) == corpus
    discard s.stop

  test "an unreachable place, or no place at all":
    let p = peer()
    p.server.close() # nothing listens there now
    let r = sh("bl send :" & $p.port, blb("1"))
    check r.code == 1
    check "can't reach 127.0.0.1:" & $p.port in r.errors
    check sh("bl reach :" & $p.port).code == 1
    check sh("bl send nowhere", blb("1")).code == 1   # the party at the place of nowhere, which nothing holds
    check sh("bl send 70000", blb("1")).code == 2
    check sh("bl send ::1:80", blb("1")).code == 2
    check sh("bl send ssh://", blb("1")).code == 2
    check sh("bl send ssh://far/", blb("1")).code == 2
    check sh("bl send ssh://far/0", blb("1")).code == 2
    check sh("bl send ssh://-oProxyCommand=x/:1", blb("1")).code == 2
    let serving = sh("bl serve ssh://far/:1")
    check serving.code == 2
    check "a listener is local" in serving.errors.splitLines[0]

  test "a unix socket or any other path is refused, exit 2":
    for place in ["unix:" & tmp / "s.sock", tmp / "s.sock", "./s.sock",
                  "../s.sock", "socks/s.sock", "ssh://far" & tmp / "s.sock",
                  "ssh://far/" & tmp / "s.sock"]:
      for cmd in ["bl send ", "bl serve ", "bl reach ",
                  "bl reach --source "]:
        let r = sh(cmd & quoteShell(place), blb("1"))
        check r.code == 2
        check r.output == ""
        check r.errors.splitLines[0].endsWith(
          "not a place: " & place & " (" &
          (if place.startsWith("ssh://"): "on the far side, " else: "") &
          "unix sockets aren't places, only TCP)")

suite "reach":
  test "duplex: stdin into the place, the place onto stdout":
    let p = peer()
    let r = startProcess(bin / "bl", args = ["reach", ":" & $p.port],
                         options = {})
    r.inputStream.write(blb("(to place)"))
    r.inputStream.close()
    check p.talk(blb("(from place)")) == blb("(to place)")
    check r.outputStream.readAll == blb("(from place)")
    check r.waitForExit == 0
    r.close

  test "-- CMD puts the place on a command's stdin and stdout":
    let p = peer()
    let r = startProcess(bin / "bl", args = ["reach", "127.0.0.1:" & $p.port,
                                             "--", "hash"], options = {})
    check p.talk(blb("\"x\"")).decoded ==
      @[digest(decoded(blb("\"x\""))[0], Sha256Algo).toValue]
    check r.waitForExit == 0
    r.close

  test "--sink only hears":
    let p = peer()
    let r = startProcess(bin / "bl", args = ["reach", "--sink",
                                             "tcp://127.0.0.1:" & $p.port],
                         options = {})
    r.inputStream.write("never sent")
    r.inputStream.close()
    check p.talk(blb("(heard)")) == ""
    check r.outputStream.readAll == blb("(heard)")
    check r.waitForExit == 0
    r.close

  test "a place that speaks more than it hears doesn't wedge the pump":
    let (port, pid) = chattyPeer(8)
    let input = file("chatty.in", "x".repeat(2 * 1024 * 1024))
    let r = startProcess("/bin/sh", args = ["-c", "exec " & bin / "bl" &
                         " reach :" & $port & " < " & input], options = {})
    let heard = readFor(cint(r.outputHandle), 16 * 1024 * 1024)
    check heard.len == 16 * 1024 * 1024
    if heard.len < 16 * 1024 * 1024:
      r.kill()
      discard kill(pid, SIGKILL)
    check r.waitForExit == 0
    r.close
    var status: cint
    discard waitpid(pid, status, 0)

  test "over ssh:// with a command, a failed ssh is a failure":
    let r = sh("bl reach --source ssh://unreachable -- read", "(one)")
    check r.code == 1
    check "ended with status 255" in r.errors

  test "over ssh://, alone and with a command":
    let s = serve(":0")
    check sh("bl reach --source ssh://far/" & s.place, blb("(one)")).code == 0
    check sh("bl reach --source ssh://far/tcp://" & s.place & " -- read",
             "(two)").code == 0
    check s.arrived(blb("(one) (two)").len) == blb("(one) (two)")
    discard s.stop
