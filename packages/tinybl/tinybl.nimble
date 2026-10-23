# Package

version = "0.1.0"
author = "mercuricchloride"
description = "An experiment with a much smaller kernel for bassline"
license = "AGPL-3.0-or-later"
srcDir = "src"

# Dependencies

requires "nim >= 2.2.10"
requires "benchy >= 0.1.0"
requires "https://github.com/nim-lang/bigints"
requires "https://github.com/Bassline-Org/petit-parser-nim"

import std/os

proc removeBinaries(dir: string) =
  for f in listFiles(dir):
    if f.splitFile.ext == "":
      rmFile f
  for d in listDirs(dir):
    if d.endsWith ".dSYM": rmDir d
    else: removeBinaries d

task clean, "remove the binaries nim c leaves beside tests/ and examples/":
  removeBinaries "tests"
  removeBinaries "examples"