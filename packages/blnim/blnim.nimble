# Package

version       = "0.1.0"
author        = "mercuricchloride"
description   = "Bassline nim implementation"
license       = "AGPL-3.0-or-later"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["blnim"]
binDir        = "bin"

# Dependencies

requires "nim >= 2.2.10"

task bench, "Run codec benchmarks":
  exec "nim r -d:release benchmarks/bench.nim"