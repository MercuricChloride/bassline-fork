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
requires "https://github.com/Bassline-Org/petit-parser-nim"
# Tasks

import std/[os, strutils]

proc removeBinaries(dir: string) =
  # A binary is a file with no extension; everything kept in tests/ and
  # examples/ has one (.nim, .nims, .bl), as .gitignore says too.
  for f in listFiles(dir):
    if f.splitFile.ext == "":
      rmFile f
  for d in listDirs(dir):
    if d.endsWith ".dSYM": rmDir d
    else: removeBinaries d

task clean, "remove the binaries nim c leaves beside tests/ and examples/":
  removeBinaries "tests"
  removeBinaries "examples"

task bench, "runs the benchmarks":
  for f in listFiles(projectDir() / "bench"):
    if f.splitFile.ext == ".nim":
      echo "running benchmark"
      exec("nim c -d:release -r " & f)
    else:
      echo "skipping file: ", f

