# `nim build` makes bin/bl, bin/bl-clave and bin/bl-jam; `nim test` builds them, then
# runs the tests against bin/. blcli.nimble names the dependencies, and
# atlas writes their paths into nim.cfg, beside the compiler flags.

task build, "build bin/bl, bin/bl-clave and bin/bl-jam":
  exec "nim c --hints:off --out:bin/bl src/bl.nim"
  exec "nim c --hints:off --out:bin/bl-clave src/bl_clave.nim"
  exec "nim c --hints:off --out:bin/bl-jam src/bl_jam.nim"

task test, "build, then run the tests against bin/":
  buildTask()
  exec "nim c -r --hints:off --out:bin/tcli tests/tcli.nim"
