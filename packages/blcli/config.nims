# `nim build` makes bin/bl, bin/bl-clave and bin/bl-jam; `nim test` builds them,
# then runs each tests/t*.nim against bin/, or only those named (`nim test jam`).
# blcli.nimble names the dependencies, and nim.cfg their paths, beside the
# compiler flags.

task build, "build bin/bl, bin/bl-clave and bin/bl-jam":
  exec "nim c --hints:off --out:bin/bl src/bl.nim"
  exec "nim c --hints:off --out:bin/bl-clave src/bl_clave.nim"
  exec "nim c --hints:off --out:bin/bl-jam src/bl_jam.nim"

import std/[algorithm, os, strutils]

task test, "build, then run every tests/t*.nim against bin/, or those named: nim test jam ws":
  buildTask()
  # the names after `test` on the command line, if any
  var named: seq[string]
  var after = false
  for i in 1 .. paramCount():
    if after: named.add paramStr(i)
    elif paramStr(i) == "test": after = true
  var failed: seq[string]
  for f in listFiles("tests").sorted:
    let (_, name, ext) = splitFile(f)
    if ext != ".nim" or not name.startsWith("t"): continue
    if named.len > 0 and name notin named and name[1 .. ^1] notin named: continue
    try: exec "nim c -r --hints:off --out:bin/" & name & " " & f
    except OSError: failed.add name
  if failed.len > 0:
    echo "failed: " & failed.join(", ")
    quit 1
