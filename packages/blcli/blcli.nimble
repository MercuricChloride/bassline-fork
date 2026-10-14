# Package

version = "0.1.0"
author = "mercuricchloride"
description = "The bl toolkit: command-line tools over bassline values"
license = "AGPL-3.0-or-later"
srcDir = "src"
binDir = "bin"
namedBin["bl"] = "bl"
namedBin["bl_clave"] = "bl-clave"   # apart, so bl carries no signing code
namedBin["bl_jam"] = "bl-jam"       # apart, with its terminal and MCP server

# Dependencies

requires "nim >= 2.2.10"
requires "blnim"

