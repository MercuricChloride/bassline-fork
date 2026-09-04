# Package

version = "0.1.0"
author = "mercuricchloride"
description = "Bassline nim implementation"
license = "AGPL-3.0-or-later"
srcDir = "src"
bin = @["bl"]
binDir = "bin"

# Dependencies

requires "nim >= 2.2.10"
requires "nimcrypto >= 0.6.2"
requires "checksums >= 0.2.2"
requires "https://github.com/Araq/malebolgia"
requires "benchy >= 0.1.0"
# ^^ This probably wont stick around