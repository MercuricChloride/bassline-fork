# Package

version = "0.1.0"
author = "mercuricchloride"
description = "The jam dialect in Nim: a jam on tracks, kept and told over TCP"
license = "AGPL-3.0-or-later"
srcDir = "src"
bin = @["jam_serve"]

# Dependencies

# bassline and bassline_crypto are core/nim and dialects/crypto/nim in this
# repository, which nim.cfg names
requires "nim >= 2.4.0"
requires "nimcrypto >= 0.6.2"
