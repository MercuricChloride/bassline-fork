##[
  Files as values: content asked by its digest, trees of names, and a
  keep that holds values filed under their digests.

    (digest blake2b H)        content, asked by its digest
    BYTES                     a file of InlineMost bytes or fewer, whole
    (chunks SIZE [D …])       a larger file, each D answered by (chunk BYTES)
    (tree {NAME: ENTRY …})    a directory, each ENTRY one of
      (file D SIZE MODE)      a file, D its content
      (dir D MODE)            a directory, D its tree
      (link TARGET)           a symbolic link

  An answer to a digest counts only when the digest is over the answer's
  CE (`verifies`), so it doesn't matter who gives it. The content is the
  artifact dialect's, so a file here is a file there. A file is put as
  bytes, never as text, so it has one digest; text content from
  elsewhere still reads as its UTF-8 bytes. MODE is the low twelve bits
  of a stat mode, without the file type.

  Chunks are cut where the content says, so the same bytes cut the same
  way wherever they are added, a file has one digest whoever adds it,
  and an edit changes only the chunks around it. The cut, which every
  implementation has to agree on byte for byte: G is a table of 256
  words, G[i] the splitmix64 output for the (i+1)th step of
  0x9E3779B97F4A7C15 from zero. From each chunk's first byte, h starts at
  zero and takes h = 2h + G[b] mod 2^64 for each byte b; the chunk ends
  at the byte where it reaches 65536 bytes, or, from 2048 bytes on,
  where the top 13 bits of h are clear. A file of 65536 bytes or fewer
  is its bytes atom and is not cut.

  A keep is a file of values one after another, a bare concatenation of
  CE, each filed under the digest of its CE. Any process may append to
  it through `store`, which holds an exclusive flock while it cuts off a
  value a writer left unfinished and appends; reading holds a shared
  one. A keep reads what was appended since whenever it is asked for
  something it hasn't seen. What content is held where is found by
  search: a keep is one search from digests to values (`keepSearch`),
  and `checked` takes several, keeping only the answers that verify.
]##

import std/[os, posix, sequtils, tables, sets]
import ../[core, mold, queries]
import ./crypto/digest
export digest

refuseWith BasslineError

moldable staticRead("fs.bl")

const
  InlineMost* = 64 * 1024  ## a file this size or smaller is its bytes atom
  MinChunk = 2 * 1024
  MaxChunk = 64 * 1024
  CutBits = 13 # cuts fall about every 2^13 bytes past the minimum
  CutMask = ((1'u64 shl CutBits) - 1) shl (64 - CutBits)
  Gear = block:
    # fixed pseudo-random words, so every cutter cuts in the same places
    var
      g: array[256, uint64]
      x = 0'u64
    for i in 0 ..< 256:
      x += 0x9E3779B97F4A7C15'u64
      var z = x
      z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
      z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
      g[i] = z xor (z shr 31)
    g

iterator cuts*(data: openArray[byte]): (int, int) =
  ## the first and last index of each chunk: a cut falls where the gear
  ## hash of the bytes since the last cut has its top bits clear
  var
    start = 0
    h = 0'u64
  for i in 0 ..< data.len:
    h = (h shl 1) + Gear[data[i]]
    let n = i - start + 1
    if n >= MaxChunk or (n >= MinChunk and (h and CutMask) == 0):
      yield (start, i)
      start = i + 1
      h = 0
  if start < data.len:
    yield (start, data.len - 1)

# ================ digests ================

proc digestOfCe(ce: openArray[byte]): Digest =
  Digest(algo: Blake2bAlgo, hash: blake2b(ce))

proc digestOf*(v: Value): Value =
  ## (digest blake2b H), H over v's CE
  digestOfCe(v.ce).mold

proc verifies*(d, v: Value): bool =
  ## whether d is the digest of v, by whichever algorithm d names
  Digest.fits(d) and Digest.load(d).verifies(v)

proc contentOf*(data: openArray[byte]): tuple[content: Value, chunks: seq[Value]] =
  ## what data is put as: its bytes atom when small, else a manifest of
  ## its chunks, with the chunks to put under their digests
  if data.len <= InlineMost:
    return (bytes(data), @[])
  var parts: seq[Digest]
  for (first, last) in cuts(data):
    let chunk = Chunk(bytes: @(data.toOpenArray(first, last))).mold
    parts.add digestOfCe(chunk.ce)
    result.chunks.add chunk
  result.content = Chunks(size: data.len, parts: parts).mold

proc named*(entry: Value): Option[Value] =
  ## the digest a tree entry names: a file's content or a directory's tree
  if FileEntry.fits(entry): some(FileEntry.load(entry).content.mold)
  elif DirEntry.fits(entry): some(DirEntry.load(entry).tree.mold)
  else: none(Value)

# ================ the keep ================

var
  LOCK_EX {.importc, header: "<sys/file.h>".}: cint
  LOCK_SH {.importc, header: "<sys/file.h>".}: cint
  LOCK_UN {.importc, header: "<sys/file.h>".}: cint

proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}

type
  Place = tuple[at, len: int]

  Keep* = ref object
    path: string
    fd: cint                    ## appended to, and locked while appending
    held: Table[Value, Place]   ## where the value filed under a digest sits
    seen: int                   ## where the last whole value read ends

proc refresh(k: Keep, locked = false) =
  ## reads what was appended since the last read, holding a shared lock
  ## unless the caller holds the exclusive one, so a cut never lands in
  ## the middle of a read. A value still being written is left for later
  let size = getFileSize(k.path).int
  if size == k.seen: return
  if not locked:
    guard flock(k.fd, LOCK_SH) == 0, "can't lock " & k.path
  defer:
    if not locked: discard flock(k.fd, LOCK_UN)
  let f = open(k.path)
  defer: f.close()
  f.setFilePos(k.seen)
  var
    d = newDecoder()
    base = k.seen # where d's buffer begins in the file
    piece = newSeq[byte](min(size - k.seen, 1 shl 20))
  while true:
    let n = f.readBytes(piece, 0, piece.len)
    if n == 0: break
    d.buf.add piece.toOpenArray(0, n - 1)
    for v in d.checked:
      k.held[digestOfCe(v.ce).mold] = (base + v.offset, v.len)
      k.seen = base + v.offset + v.len
    let had = d.buf.len
    d.compact
    base += had - d.buf.len

proc openKeep*(path: string): Keep =
  ## the keep in `path`, made if there is none
  if path.parentDir.len > 0: createDir(path.parentDir)
  let fd = posix.open(path.cstring, O_WRONLY or O_APPEND or O_CREAT, 0o644)
  if fd < 0: raiseOSError(osLastError(), path)
  result = Keep(path: path, fd: fd)
  result.refresh()

proc close*(k: Keep) =
  if k.fd >= 0:
    discard posix.close(k.fd)
    k.fd = -1

proc holds*(k: Keep, d: Value): bool =
  ## whether the keep holds what d is the digest of, as far as the file
  ## says now
  if d notin k.held: k.refresh()
  d in k.held

proc fetch*(k: Keep, d: Value): Option[Value] =
  ## what the keep holds under d, read from where it sits and checked
  if not k.holds(d): return none(Value)
  let (at, len) = k.held[d]
  var ce = newSeq[byte](len)
  let f = open(k.path)
  defer: f.close()
  f.setFilePos(at)
  guard f.readBytes(ce, 0, len) == len, k.path & " ends inside a value"
  guard Digest.load(d).verifies(ce), "the value at " & $at & " in " & k.path &
    " is not " & $d
  some(Value.decode(ce))

proc store*(k: Keep, v: Value): Value =
  ## v filed under its digest, which it answers, written unless the keep
  ## holds it already. Refuses a value larger than a keep reads back
  let ce = v.ce
  guard ce.len <= MaxValueBytes, "a keep holds values of " & $MaxValueBytes &
    " bytes at most, and this one is " & $ce.len
  result = digestOfCe(ce).mold
  if k.holds(result): return
  guard flock(k.fd, LOCK_EX) == 0, "can't lock " & k.path
  defer: discard flock(k.fd, LOCK_UN)
  k.refresh(locked = true)
  if result in k.held: return
  let size = getFileSize(k.path).int
  if size > k.seen:
    # a value cut short, by a writer that never finished: nobody writes
    # while the lock is held, so it is cut off
    guard ftruncate(k.fd, Off(k.seen)) == 0, "can't cut " & k.path
  var written = 0
  while written < ce.len:
    let n = posix.write(k.fd, ce[written].unsafeAddr, ce.len - written)
    if n < 0: raiseOSError(osLastError(), k.path)
    written += n
  k.held[result] = (k.seen, ce.len)
  k.seen += ce.len

proc held*(k: Keep): seq[Value] =
  ## every digest the keep holds
  k.refresh()
  k.held.keys.toSeq

proc keepSearch*(k: Keep): Search[Value, Value] =
  ## a digest to what the keep holds under it. What sits in the keep
  ## under d and isn't what d is the digest of is no answer
  newSearch[Value, Value]((d: Value) => (block:
    let v = try: k.fetch(d) except BasslineError: none(Value)
    if v.isSome: just(v.get) else: empty(Value)))

# ================ adding ================

proc modeOf(st: Stat): BNum =
  int(st.st_mode) and 0o7777

proc lstatOf(path: string): Stat =
  if lstat(path.cstring, result) != 0:
    raiseOSError(osLastError(), path)

proc isText(s: string): bool =
  isValidUtf8(s.toOpenArrayByte(0, s.high))

proc addBytes*(k: Keep, data: openArray[byte]): Value =
  ## data's content and chunks stored, and the content's digest
  let (content, chunks) = contentOf(data)
  for c in chunks: discard k.store(c)
  k.store(content)

proc add*(k: Keep, path: string, skip: (string, string) -> void = nil): Value =
  ## the entry for the file, directory or link at `path`, everything
  ## under it stored. What can't be added is passed to `skip` with why:
  ## a name that isn't UTF-8, the keep's own file, and what is neither a
  ## file, a directory nor a link
  let self = lstatOf(k.path)
  proc skipped(path, why: string) =
    if skip != nil: skip(path, why)
  proc go(path: string, st: Stat): Option[Value] =
    if st.st_dev == self.st_dev and st.st_ino == self.st_ino:
      skipped(path, "it is the keep being written")
    elif S_ISLNK(st.st_mode):
      let target = expandSymlink(path)
      if target.isText: return some(LinkEntry(target: target).mold)
      skipped(path, "it links to a path that is not UTF-8")
    elif S_ISREG(st.st_mode):
      let data = readFile(path)
      let d = k.addBytes(data.toOpenArrayByte(0, data.high))
      return some(FileEntry(content: Digest.load(d), size: data.len,
                            mode: modeOf(st)).mold)
    elif S_ISDIR(st.st_mode):
      var entries: seq[tuple[key: string, val: Value]]
      for _, child in walkDir(path, checkDir = true):
        let name = extractFilename(child)
        if not name.isText:
          skipped(child, "its name is not UTF-8, so not text")
          continue
        try:
          let e = go(child, lstatOf(child))
          if e.isSome: entries.add (name, e.get)
        except OSError, IOError:
          skipped(child, getCurrentExceptionMsg())
      let tree = k.store(FsTree(entries: entries).mold)
      return some(DirEntry(tree: Digest.load(tree), mode: modeOf(st)).mold)
    else:
      skipped(path, "not a file, directory or link")
    none(Value)
  let e = go(path, lstatOf(path))
  guard e.isSome, "nothing to add at " & path
  e.get

# ================ reading ================

proc checked*(sources: varargs[Search[Value, Value]]): Search[Value, Value] =
  ## the sources' answers to a digest, taking turns, passing over every
  ## answer the digest isn't of. Every answer that verifies is the one
  ## value the digest is of, so it is answered once however many hold it
  let sources = @sources
  newSearch[Value, Value]((d: Value) =>
    alt(sources.mapIt(it.ask(d))).filter((v: Value) => verifies(d, v)).unique)

proc answerOf*(s: Search[Value, Value], d: Value): Option[Value] =
  ## the first answer s gives to d that d is the digest of: the readers
  ## below check every answer themselves, whatever search they are given
  s.ask(d).filter((v: Value) => verifies(d, v))()

proc missing*(s: Search[Value, Value], d: Value): seq[Value] =
  ## the digests under d, d among them, that s has no answer for: a
  ## manifest's chunks and a tree's entries, all the way down. Below a
  ## digest with no answer nothing more can be known
  var
    seen: HashSet[Value]
    lacking: seq[Value]
  proc go(d: Value) =
    if seen.containsOrIncl(d): return
    let a = s.answerOf(d)
    if a.isNone:
      lacking.add d
    elif Chunks.fits(a.get):
      for p in Chunks.load(a.get).parts: go(p.mold)
    elif FsTree.fits(a.get):
      for (_, e) in FsTree.load(a.get).entries:
        let n = named(e)
        if n.isSome: go(n.get)
  go(d)
  lacking

proc bytesOf*(s: Search[Value, Value], d: Value): Option[seq[byte]] =
  ## the content d is the digest of, whole, if s has all of it. Text
  ## content, as the artifact dialect allows, is its UTF-8 bytes
  let a = s.answerOf(d)
  if a.isNone: return
  let v = a.get
  if v.isKind(bBytes, unmarked): return some(v.bytes)
  if v.isKind(bText, unmarked): return some(@(v.text.toOpenArrayByte(0, v.text.high)))
  if not Chunks.fits(v): return
  let m = Chunks.load(v)
  var data: seq[byte]
  for p in m.parts:
    let c = s.answerOf(p.mold)
    if c.isNone: return
    guard Chunk.fits(c.get), $d & " names a part that is not a chunk: " & $p.mold
    data.add Chunk.load(c.get).bytes
  guard data.len == m.size.toInt, $d & " says " & $m.size &
    " bytes and its chunks hold " & $data.len
  some(data)

proc treeOf(s: Search[Value, Value], entry: Value): Option[FsTree] =
  ## the tree a directory entry, or a tree's own digest, names
  let d = if DirEntry.fits(entry): named(entry) else: some(entry)
  let t = s.answerOf(d.get)
  if t.isSome and FsTree.fits(t.get): some(FsTree.load(t.get))
  else: none(FsTree)

proc listing*(s: Search[Value, Value], tree: Value): Option[seq[(string, Value)]] =
  ## the names in a directory and their entries, by name, if s has the
  ## tree. `tree` is a directory entry or a tree's digest
  let t = s.treeOf(tree)
  if t.isSome: some(t.get.entries.mapIt((it.key, it.val)))
  else: none(seq[(string, Value)])

proc steps(s: Search[Value, Value], entry: Value, path: seq[string],
           top: bool): Stream[Value] =
  ## the entries `path` names from `entry`: through directory entries,
  ## and through a bare digest only where the walk begins
  if path.len == 0: return just(entry)
  if not DirEntry.fits(entry) and not (top and Digest.fits(entry)):
    return empty(Value)
  let
    d = if DirEntry.fits(entry): named(entry).get else: entry
    rest = path[1 .. ^1]
  s.ask(d).filter((t: Value) => verifies(d, t)).flatMap((t: Value) => (block:
    if not FsTree.fits(t): return empty(Value)
    for (k, e) in FsTree.load(t).entries:
      if k == path[0]: return s.steps(e, rest, false)
    empty(Value)))

proc walk*(s: Search[Value, Value], entry: Value,
           path: openArray[string]): Stream[Value] =
  ## the entries `path` names from `entry`, a directory entry or a tree's
  ## digest, one name a step. Inside a tree only a directory entry is
  ## walked through, as only the three entries are written out
  s.steps(entry, @path, true)

proc checkName(name: string) =
  ## a name is one part of a path: writing out writes nothing outside
  ## where it was asked to
  guard name.len > 0 and name != "." and name != ".." and
    '/' notin name and '\0' notin name, "not a name to write: " & name

proc writtenMode(mode: BNum, dest: string): Mode =
  ## a mode as it is written: one of twelve bits, without setuid, setgid
  ## and sticky, which a tree from anyone has no business setting
  guard mode.isInt and mode.toInt in 0 .. 0o7777, dest & " has no mode " & $mode
  Mode(mode.toInt and 0o777)

proc setMode(dest: string, mode: Mode) =
  guard chmod(dest.cstring, mode) == 0, "can't set the mode of " & dest

proc write(s: Search[Value, Value], entry: Value, dest: string, top, dry: bool) =
  ## writes `entry` at `dest`, or with `dry` only checks that it could:
  ## that s has every part, and every name, size and mode will do
  if LinkEntry.fits(entry):
    if not dry: createSymlink(LinkEntry.load(entry).target, dest)
  elif FileEntry.fits(entry) or (top and Digest.fits(entry) and s.treeOf(entry).isNone):
    let
      d = if FileEntry.fits(entry): named(entry).get else: entry
      data = s.bytesOf(d)
    guard data.isSome, "missing some of " & $d
    var mode = none(Mode)
    if FileEntry.fits(entry):
      let e = FileEntry.load(entry)
      guard data.get.len == e.size.toInt, dest & " is not " & $e.size & " bytes"
      mode = some writtenMode(e.mode, dest)
    if dry: return
    writeFile(dest, data.get)
    if mode.isSome: setMode(dest, mode.get)
  elif DirEntry.fits(entry) or (top and Digest.fits(entry)):
    let t = s.treeOf(entry)
    guard t.isSome, "missing the tree " & $(if DirEntry.fits(entry): named(entry).get else: entry)
    let mode = if DirEntry.fits(entry): some writtenMode(DirEntry.load(entry).mode, dest)
               else: none(Mode)
    if not dry: createDir(dest)
    var links: seq[(string, Value)]
    for (name, e) in t.get.entries:
      checkName(name)
      if LinkEntry.fits(e): links.add (name, e)  # last, so nothing is written through a link
      else: s.write(e, dest / name, false, dry)
    for (name, e) in links:
      s.write(e, dest / name, false, dry)
    if not dry and mode.isSome: setMode(dest, mode.get)
  elif top:
    refuse "not a file, directory, link or digest: " & $entry
  else:
    refuse "not a file, directory or link entry: " & $entry

proc writeOut*(s: Search[Value, Value], entry: Value, dest: string) =
  ## the file, directory or link `entry` describes, written at `dest`. A
  ## bare digest is written as what it answers: content as a file, a
  ## tree as a directory; inside a tree only the three entries are
  ## written. Refuses a `dest` already there, and, before writing
  ## anything, what s lacks any part of or what won't do. Modes are
  ## written without their setuid, setgid and sticky bits
  guard not fileExists(dest) and not dirExists(dest) and not symlinkExists(dest),
    dest & " is there already"
  s.write(entry, dest, true, dry = true)
  s.write(entry, dest, true, dry = false)
