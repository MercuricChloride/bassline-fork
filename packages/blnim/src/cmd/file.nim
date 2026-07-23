import std/os
import zippy
import zippy/tarballs
import ../core
import ../lib/common
import ./util

const help = """
bl file <path> [--zip]

Writes the file at <path> to stdout as the binary encoding of
(file #[contents] {name: "<basename>"}).

A directory becomes (directory #{entries} {name: "<basename>"}),
recursing into files and subdirectories.

Options:
  --zip   compress: a file's contents are gzipped and its info
          gains zip: gzip; a directory is packed whole as a .tar.gz
          file record whose info gains zip: tarball
"""

proc info(path: string, zip = ""): BlFileInfo =
  result.name = some lastPathPart(path)
  if zip != "":
    result.zip = some Sym(zip)

proc tarball(path: string): Value =
  let tmp = getTempDir() / "bl-tarball-" & $getCurrentProcessId() & ".tar.gz"
  try:
    try:
      createTarball(path, tmp)
    except CatchableError as e:
      quit "can't tarball " & path & " -- " & e.msg
    BlFile(contents: readFile(tmp).toBytes, info: some info(path, zip = "tarball")).toValue
  finally:
    if fileExists(tmp):
      removeFile(tmp)

proc valueOfPath(path: string, zip: bool): Value =
  if dirExists(path):
    if zip:
      tarball(path)
    else:
      var entries: seq[Value]
      for kind, entryPath in walkDir(path):
        case kind
        of pcFile, pcDir:
          try:
            entries.add valueOfPath(entryPath, zip = false)
          except IOError as e:
            # sockets, fifos, unreadables: walkDir calls them files,
            # but we say shutup, nerd!
            stderr.writeLine "-- skipping " & entryPath & ": " & e.msg
        else:
          discard # symlinks and the like we just skip for now
      toValue Directory(entries: entries, info: some info(path))
  else:
    let contents = readFile(path)
    if zip:
      BlFile(
        contents: compress(contents, dataFormat = dfGzip).toBytes,
        info: some info(path, zip = "gzip"),
      ).toValue
    else:
      toValue BlFile(contents: toBytes(contents), info: some info(path))

proc run*(args: seq[string]) =
  var
    path = ""
    zip = false
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["help", "zip"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "zip":
        if val != "":
          quit "--zip takes no value, got: " & val
        zip = true
      else:
        quit "unknown file option: " & key & "\n\n" & help
    else:
      if path != "":
        quit "file takes exactly one path\n\n" & help
      path = key

  if path == "":
    quit "file needs a path\n\n" & help
  if not fileExists(path) and not dirExists(path):
    quit "no such file or directory: " & path

  let ce =
    try:
      encode(valueOfPath(path, zip))
    except IOError as e:
      quit "can't read " & path & " -- " & e.msg
  if stdout.writeBuffer(addr ce[0], ce.len) != ce.len:
    quit "short write to stdout"
  stdout.flushFile()
