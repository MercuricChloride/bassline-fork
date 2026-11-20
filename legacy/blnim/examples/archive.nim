## blarc: a directory archiver over moldable types (archive.bl). An
## archive is a run of CE records: chunks and directories, each once,
## filed under its digest, and snapshots naming a root directory.
## Packing into an archive that exists appends a snapshot and only the
## records it doesn't already hold.
##
##   blarc pack DIR ARCHIVE         append a snapshot of DIR
##   blarc snapshots ARCHIVE        what each snapshot holds
##   blarc ls ARCHIVE [N]           the tree of snapshot N, the last by default
##   blarc unpack ARCHIVE DEST [N]  write snapshot N out as DEST
##   blarc verify ARCHIVE           every snapshot has its chunks
##
## Chunks are cut where the content says (a gear hash), so an edit
## changes only the chunks around it. A record's digest, over its CE, is
## how a file names its chunks and a directory the directories in it,
## so an edit rewrites only its chunks and the directories above it.

import std/[os, posix, sets, tables, strutils, times]
import bl/mold

refuseWith BasslineError
from bl/lib/crypto/digest import blake2b
from bl/lib/fs import cuts

moldable staticRead("archive.bl")

proc digestOf(ce: openArray[byte]): Digest =
  Digest(algo: "blake2b", hash: @(blake2b(ce)))

proc spelled(s: string): Value =
  ## s as text when it is UTF-8, else as the bytes it is
  if isValidUtf8(s.toOpenArrayByte(0, s.high)): text(s)
  else: bytes(s.toOpenArrayByte(0, s.high))

proc isText(s: string): bool =
  isValidUtf8(s.toOpenArrayByte(0, s.high))

proc put(f: system.File, bytes: openArray[byte]) =
  guard f.writeBytes(bytes, 0, bytes.len) == bytes.len, "a write fell short"

proc lstatOf(path: string): Stat =
  if lstat(path.cstring, result) != 0:
    raiseOSError(osLastError(), path)

proc modeOf(st: Stat): BNum =
  int(st.st_mode) and 0o7777

# ================ Reading an archive ================

iterator records(path: string, whole: var int): Found =
  ## each record in the archive, with the digest of its CE and where it
  ## sits. `whole` ends up where the last whole record ends: past it is a
  ## record cut short, as by a pack that never finished
  let f = open(path)
  defer: f.close()
  var
    d = newDecoder()
    base = 0 # where d's buffer begins in the file
    piece = newSeq[byte](1 shl 20)
  whole = 0
  while true:
    let n = f.readBytes(piece, 0, piece.len)
    if n == 0: break
    d.buf.add piece.toOpenArray(0, n - 1)
    for v in d.checked:
      yield Found(value: v.toValue, digest: digestOf(v.ce),
                  place: Place(at: base + v.offset, len: v.len))
      whole = base + v.offset + v.len
    let held = d.buf.len
    d.compact
    base += held - d.buf.len

func isRecordOf(v, head: Value): bool =
  v.isKind(bRec) and v.len > 0 and v.items[0] == head

type Archive = object
  path: string
  file: system.File        # to fetch records from
  held: Table[Value, Place] # where the record filed under a digest sits
  snapshots: seq[Found]     # in order
  whole: int

proc open(_: type Archive, path: string): Archive =
  result.path = path
  if not fileExists(path): return
  for found in records(path, result.whole):
    if found.value.isRecordOf(Snapshot.head):
      result.snapshots.add found
    else:
      result.held[found.digest.mold] = found.place
  result.file = open(path)

proc close(a: Archive) =
  if a.file != nil: a.file.close()

proc snapshot(a: Archive, n: int): Snapshot =
  ## snapshot n, counting from 0; -1 is the last
  let i = if n < 0: a.snapshots.len + n else: n
  guard i in 0 ..< a.snapshots.len,
    a.path & " has " & $a.snapshots.len & " snapshots, not one numbered " & $n
  Snapshot.load(a.snapshots[i].value)

proc holds(a: Archive, d: Digest): bool =
  d.mold in a.held

proc fetch(a: Archive, d: Digest): Value =
  ## the record d names, read from where it sits and checked against d
  guard a.holds(d), a.path & " holds nothing filed under " & $d.mold
  let
    at = a.held[d.mold].at.toInt
    len = a.held[d.mold].len.toInt
  var ce = newSeq[byte](len)
  a.file.setFilePos(at)
  guard a.file.readBytes(ce, 0, len) == len, a.path & " ends inside a record"
  guard @(blake2b(ce)) == d.hash, "the record at " & $at & " is not " & $d.mold
  Value.decode(ce)

proc chunk(a: Archive, d: Digest): seq[byte] =
  Chunk.load(a.fetch(d)).bytes

proc dir(a: Archive, d: Digest): Dir =
  Dir.load(a.fetch(d))

# ================ pack ================

type Packer = object
  archive: system.File
  self: Stat               # the archive's own file, never packed into itself
  held: HashSet[Value] # digests of the records the archive holds
  files, dirs, links, bytes, chunks, newChunks, newDirs, stored: int
  skipped: seq[Skipped]

proc store(p: var Packer, v: Value): tuple[d: Digest, fresh: bool] =
  ## v filed under its digest, and written unless the archive holds it
  let ce = v.ce
  result.d = digestOf(ce)
  if not p.held.containsOrIncl(result.d.mold):
    p.archive.put ce
    p.stored += ce.len
    result.fresh = true

proc skip(p: var Packer, path, why: string) =
  p.skipped.add Skipped(path: spelled(path), why: why)
  stderr.writeLine "skipped ", path, ": ", why

proc packFile(p: var Packer, path, name: string, st: Stat): Entry =
  let data = readFile(path)
  result = Entry(name: name, mode: modeOf(st), size: data.len)
  for (first, last) in cuts(data.toOpenArrayByte(0, data.high)):
    let (d, fresh) = p.store(Chunk(bytes: @(data.toOpenArrayByte(first, last))).mold)
    inc p.chunks
    if fresh: inc p.newChunks
    result.chunks.add d
  inc p.files
  p.bytes += data.len

proc packDir(p: var Packer, path, name: string, st: Stat): Digest =
  var dir = Dir(name: name, mode: modeOf(st))
  for _, child in walkDir(path):
    let name = extractFilename(child)
    if not name.isText:
      p.skip(child, "its name is not UTF-8, so not text")
      continue
    try:
      let cst = lstatOf(child)
      if cst.st_dev == p.self.st_dev and cst.st_ino == p.self.st_ino:
        p.skip(child, "it is the archive being written")
      elif S_ISLNK(cst.st_mode):
        let target = expandSymlink(child)
        if not target.isText:
          p.skip(child, "it links to a path that is not UTF-8")
          continue
        dir.links.add Link(name: name, target: target)
        inc p.links
      elif S_ISDIR(cst.st_mode):
        dir.dirs.add p.packDir(child, name, cst)
      elif S_ISREG(cst.st_mode):
        dir.files.add p.packFile(child, name, cst)
      else:
        p.skip(child, "not a file, directory or link")
    except OSError, IOError:
      p.skip(child, getCurrentExceptionMsg())
  inc p.dirs
  let (d, fresh) = p.store(dir.mold)
  if fresh: inc p.newDirs
  d

proc pack(dir, path: string) =
  let a = Archive.open(path)
  a.close()
  if fileExists(path) and a.whole < getFileSize(path):
    # a pack that never finished left a record cut short: start clean
    guard truncate(path.cstring, Off(a.whole)) == 0, "can't cut " & path
  var p = Packer(archive: open(path, fmAppend))
  defer: p.archive.close()
  p.self = lstatOf(path)
  for d in a.held.keys:
    p.held.incl d
  let
    root = p.packDir(dir, extractFilename(absolutePath(dir)), lstatOf(dir))
    ce = Snapshot(root: root, made: some(getTime().toUnix.int.toNum)).mold.ce
  p.archive.put ce
  echo pretty(Packed(snapshot: a.snapshots.len, id: root, files: p.files,
    dirs: p.dirs, links: p.links, bytes: p.bytes, chunks: p.chunks,
    newChunks: p.newChunks, newDirs: p.newDirs, stored: p.stored + ce.len,
    skipped: p.skipped).mold)

# ================ snapshots, ls ================

proc tally(a: Archive, d: Digest, files, bytes: var int) =
  let dir = a.dir(d)
  for f in dir.files:
    inc files
    bytes += f.size.toInt
  for sub in dir.dirs:
    a.tally(sub, files, bytes)

proc snapshots(path: string) =
  let a = Archive.open(path)
  defer: a.close()
  for i, found in a.snapshots:
    let s = Snapshot.load(found.value)
    var files, bytes: int
    a.tally(s.root, files, bytes)
    var held = Held(n: i, place: found.place, id: s.root, files: files,
                    bytes: bytes)
    if s.made.isSome:
      held.made = some($fromUnix(s.made.get.toInt).utc)
    echo held

proc list(a: Archive, d: Digest, prefix: string) =
  let dir = a.dir(d)
  for f in dir.files:
    echo ($f.size).align(12), "  ", prefix & f.name
  for l in dir.links:
    echo "        link  ", prefix & l.name, " -> ", l.target
  for subDigest in dir.dirs:
    let sub = a.dir(subDigest)
    echo "         dir  ", prefix & sub.name, "/"
    a.list(subDigest, prefix & sub.name & "/")

proc ls(path: string, n: int) =
  let a = Archive.open(path)
  defer: a.close()
  a.list(a.snapshot(n).root, "")

# ================ unpack ================

proc checkName(name: string) =
  ## a name is one part of a path: unpacking writes nothing outside DEST
  guard name.len > 0 and name != "." and name != ".." and
    '/' notin name and '\0' notin name, "not a name to write: " & name

proc unpackDir(a: Archive, d: Dir, path: string) =
  createDir(path)
  var names: HashSet[string]
  template claim(name: string) =
    checkName(name)
    guard not names.containsOrIncl(name),
      path / name & " is described twice"
  for e in d.files:
    claim e.name
    let dest = open(path / e.name, fmWrite)
    defer: dest.close()
    var written = 0
    for c in e.chunks:
      let bytes = a.chunk(c)
      dest.put bytes
      written += bytes.len
    guard written == e.size.toInt, path / e.name & " is not " & $e.size &
      " bytes"
    discard chmod((path / e.name).cstring, Mode(e.mode.toInt))
  for subDigest in d.dirs:
    let sub = a.dir(subDigest)
    claim sub.name
    a.unpackDir(sub, path / sub.name)
  for l in d.links:
    # last, so nothing is written through a link
    claim l.name
    createSymlink(l.target, path / l.name)
  discard chmod(path.cstring, Mode(d.mode.toInt))

proc unpack(path, dest: string, n: int) =
  let a = Archive.open(path)
  defer: a.close()
  guard not dirExists(dest), dest & " is there already"
  a.unpackDir(a.dir(a.snapshot(n).root), dest)

# ================ verify ================

proc verify(path: string) =
  ## every directory and chunk a snapshot names is held, and reads as
  ## one; a directory several snapshots share is looked at once
  let a = Archive.open(path)
  defer: a.close()
  var
    v = Verified(records: a.held.len, snapshots: a.snapshots.len)
    seen: HashSet[Value]
  proc walk(d: Digest) =
    if seen.containsOrIncl(d.mold): return
    if not a.holds(d):
      v.missing.add d
      return
    let dir = a.dir(d)
    for e in dir.files:
      for c in e.chunks:
        if not a.holds(c): v.missing.add c
    for sub in dir.dirs: walk(sub)
  for found in a.snapshots:
    walk(Snapshot.load(found.value).root)
  echo v
  if v.missing.len > 0: quit 1

# ================ main ================

proc usage() =
  stderr.writeLine """usage: blarc pack DIR ARCHIVE
       blarc snapshots ARCHIVE
       blarc ls ARCHIVE [N]
       blarc unpack ARCHIVE DEST [N]
       blarc verify ARCHIVE"""
  quit 2

when isMainModule:
  let args = commandLineParams()
  if args.len < 2: usage()
  try:
    case args[0]
    of "pack":
      if args.len != 3: usage()
      pack(args[1], args[2])
    of "snapshots":
      snapshots(args[1])
    of "ls":
      ls(args[1], if args.len > 2: parseInt(args[2]) else: -1)
    of "unpack":
      if args.len < 3: usage()
      unpack(args[1], args[2], if args.len > 3: parseInt(args[3]) else: -1)
    of "verify":
      verify(args[1])
    else:
      usage()
  except BasslineError, OSError, IOError, ValueError:
    stderr.writeLine "blarc: ", getCurrentExceptionMsg()
    quit 1