import std/[parseopt, os]
import zippy
import zippy/tarballs
import ../blnim/misc/common
import ../blnim/codec/encode

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

proc info(path: string; zip = ""): Value =
  var entries = @[(sym"name", text(lastPathPart(path)))]
  if zip != "":
    entries.add (sym"zip", sym(zip))
  dict(entries)

proc tarball(path: string): Value =
  let tmp = getTempDir() / "bl-tarball-" & $getCurrentProcessId() & ".tar.gz"
  try:
    try:
      createTarball(path, tmp)
    except CatchableError as e:
      quit "can't tarball " & path & " -- " & e.msg
    common.file(readFile(tmp), info(path, zip = "tarball"))
  finally:
    if fileExists(tmp):
      removeFile(tmp)

proc valueOfPath(path: string; zip: bool): Value =
  if dirExists(path):
    if zip:
      tarball(path)
    else:
      var entries: seq[Value]
      for kind, entryPath in walkDir(path):
        case kind
        of pcFile, pcDir:
          entries.add valueOfPath(entryPath, zip = false)
        else:
          discard  # symlinks and the like we just skip for now
      directory(entries, info(path))
  else:
    let contents = readFile(path)
    if zip:
      common.file(compress(contents, dataFormat = dfGzip),
                  info(path, zip = "gzip"))
    else:
      common.file(contents, info(path))

proc run*(args: seq[string]) =
  var
    path = ""
    zip = false
  var p = initOptParser(args, shortNoVal = {'h'}, longNoVal = @["help", "zip"])
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        echo help
        return
      of "zip":
        if p.val != "":
          quit "--zip takes no value, got: " & p.val
        zip = true
      else:
        quit "unknown file option: " & p.key & "\n\n" & help
    of cmdArgument:
      if path != "":
        quit "file takes exactly one path\n\n" & help
      path = p.key

  if path == "":
    quit "file needs a path\n\n" & help
  if not fileExists(path) and not dirExists(path):
    quit "no such file or directory: " & path

  let ce = encode(valueOfPath(path, zip))
  if stdout.writeBuffer(addr ce[0], ce.len) != ce.len:
    quit "short write to stdout"
  stdout.flushFile()
