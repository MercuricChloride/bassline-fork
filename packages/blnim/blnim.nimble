# Package

version = "0.1.0"
author = "mercuricchloride"
description = "Bassline nim implementation"
license = "AGPL-3.0-or-later"
srcDir = "src"
installExt = @["nim"]
bin = @["bl"]
binDir = "bin"

# Dependencies

requires "nim >= 2.2.10"
requires "zippy >= 0.10.19"
requires "nimcrypto >= 0.6.2"

task build_release, "Build for production":
  switch("mm", "orc")
  switch("d", "release")
  switch("outdir", "bin")
  setCommand "c", "src/bl.nim"