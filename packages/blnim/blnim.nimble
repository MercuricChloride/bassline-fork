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

requires "checksums >= 0.2.1"
requires "monocypher >= 0.3.0"
