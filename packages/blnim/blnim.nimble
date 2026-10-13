# Package

version = "0.1.0"
author = "mercuricchloride"
description = "Bassline nim implementation"
license = "AGPL-3.0-or-later"
srcDir = "src"
binDir = "bin"

# Dependencies

requires "nim >= 2.2.10"
requires "nimcrypto >= 0.6.2"
requires "checksums >= 0.2.2"
requires "benchy >= 0.1.0"
requires "https://github.com/nim-lang/bigints"
requires "petit_parser"
# Tasks

import std/[os, strutils]

task clean, "remove the binaries nim c -r leaves beside tests/*.nim":
  # A test binary is a file in tests/ with no extension; everything
  # kept there has one (.nim, .nims), as tests/.gitignore says too.
  for f in listFiles("tests"):
    if f.splitFile.ext == "":
      rmFile f
  for d in listDirs("tests"):
    if d.endsWith ".dSYM":
      rmDir d
