import std/[os, sets, algorithm, sequtils]
from std/strutils import nil
import zippy
import zippy/tarballs
import pkg/core
import pkg/lib/[common, reader]
import pkg/lib/crypto/digest
import ./util

const help = """
bl file <path> [--chunk:BYTES] [--zip]

Writes the tree at <path> to stdout as names, not contents.

Every file is cut into bounded (chunk <offset> 0x<bytes>) values,
each written the moment it is read, and the file itself becomes
(file <root> [<leaf>...] {name: "<basename>"}). A directory becomes
(dir <root> [<child>...] {name: "<basename>"}), its children in CE
order so two runs over one tree say the same thing.

Chunks come before the manifest that names them and the root
manifest is the last value written, so nothing downstream ever holds
a name it cannot already resolve. A repeated chunk is written once.
Memory is one chunk plus the names, whatever the tree weighs.

`bl assemble` puts it back.

Options:
  --chunk:BYTES  chunk size, default 1048576
  --zip          pack whole instead of chunking: a file's contents are
                 gzipped into (file 0x<contents> {name, zip: gzip}), a
                 directory into one .tar.gz file record. Holds the
                 whole thing in memory; the chunked form does not
"""

const DefaultChunk = 1024 * 1024

proc readBytes(path: string): seq[byte] =
  var f: File
  if not f.open(path, fmRead):
    raise newException(IOError, "cannot open: " & path)
  defer: f.close()
  let n = f.getFileSize.int
  result = newSeqUninit[byte](n)
  if n > 0:
    let got = f.readBuffer(addr result[0], n)
    result.setLen(got)

proc nameOf(path: string): string =
  ## `.`, `..` and a trailing slash are ways of pointing at a thing,
  ## not what it is called. Resolve them before asking for a name, or a
  ## tree said from inside itself lands as a manifest named "." that no
  ## receiver can honestly lay down.
  let p = path.absolutePath.normalizedPath
  result = p.lastPathPart
  if result.len == 0:
    result = "root" # the filesystem root has no basename to borrow

proc info(path: string, zip = ""): BlFileInfo =
  result.name = some nameOf(path)
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
      toValue Directory(entries: move(entries), info: some info(path))
  elif zip:
    BlFile(
      contents: compress(readFile(path), dataFormat = dfGzip).toBytes,
      info: some info(path, zip = "gzip"),
    ).toValue
  else:
    toValue BlFile(contents: readBytes(path), info: some info(path))

# ================ CHUNKED ================

type Seen = HashSet[seq[byte]]

func rootOf(ds: seq[Digest]): Digest =
  ## A name for the content alone. The manifest record names content
  ## and its trappings together; this names only what the leaves say,
  ## so two files that differ just in what they are called share it.
  digest list(ds.mapIt(toValue it))

proc emitChunks(
    path: string, w: var ValueWriter, seen: var Seen, size: int
): seq[Digest] =
  ## Cuts one file into chunks, writing each as it is read. Only the
  ## names are kept, so a file of any weight costs one chunk of room.
  var f: File
  if not f.open(path, fmRead):
    raise newException(IOError, "cannot open: " & path)
  defer:
    f.close()
  var prev = none Digest
  while true:
    var b = newSeqUninit[byte](size)
    let got = if size > 0: f.readBuffer(addr b[0], size) else: 0
    if got <= 0:
      break
    b.setLen(got)
    let c = toValue Chunk(prev: prev, bytes: move(b))
    let d = digest c
    if not seen.containsOrIncl(d.hash):
      w.writeValue c
    result.add d
    prev = some d

proc chunkPath(
    path: string, w: var ValueWriter, seen: var Seen, size: int
): Digest =
  ## Writes everything under `path` and answers with the name of the
  ## manifest that speaks for it.
  if dirExists(path):
    var kids: seq[Digest]
    for kind, entryPath in walkDir(path):
      case kind
      of pcFile, pcDir:
        try:
          kids.add chunkPath(entryPath, w, seen, size)
        except IOError as e:
          stderr.writeLine "-- skipping " & entryPath & ": " & e.msg
      else:
        discard # symlinks and the like we just skip for now
    # a list keeps the order it was given, and walkDir's order is the
    # filesystem's business, so put the children in CE order by hand:
    # two runs over one tree have to say the same thing
    kids.sort(
      proc(a, b: Digest): int =
        cmp(toValue a, toValue b)
    )
    let m = toValue DirManifest(
      root: rootOf(kids), entries: kids, info: some info(path)
    )
    w.writeValue m
    digest m
  else:
    let leaves = emitChunks(path, w, seen, size)
    let m = toValue FileManifest(
      root: rootOf(leaves), leaves: leaves, info: some info(path)
    )
    w.writeValue m
    digest m

proc runChunked(path: string, size: int) =
  var
    w = writerOn(stdout)
    seen: Seen
  let root =
    try:
      chunkPath(path, w, seen, size)
    except IOError as e:
      quit "can't read " & path & " -- " & e.msg
  w.flush()
  stdout.flushFile()
  # the root manifest is also the last value written; saying its name
  # here saves fishing it back out of the stream
  stderr.writeLine "-- root " & $toValue(root)

proc run*(args: seq[string]) =
  var
    path = ""
    zip = false
    chunkSize = DefaultChunk
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
      of "chunk":
        try:
          chunkSize = strutils.parseInt(val)
        except ValueError:
          quit "--chunk wants a byte count, got: " & val
        if chunkSize < 1:
          quit "--chunk must be at least 1, got: " & val
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

  if not zip:
    runChunked(path, chunkSize)
    return

  # --zip still says a tree the whole-contents way, and so still holds
  # it all at once. The chunked form is the one that doesn't.
  let v =
    try:
      valueOfPath(path, zip)
    except IOError as e:
      quit "can't read " & path & " -- " & e.msg
  emit v
