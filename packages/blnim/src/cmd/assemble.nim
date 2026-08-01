## Puts back what `bl file` said.
##
## Nothing here depends on the order things arrive in, nor on the input
## ever ending. Chunks are held in one store and manifests in another,
## whether or not what they name has shown up yet.
##
## The roots are then read off the manifest store: the manifests no
## other manifest names. That is a question about what the store holds,
## not about the stream -- so a transfer that arrived down a pipe that
## never closes is asked the same way as one from a file, and a tree can
## be laid down long after whatever carried it has gone.

import std/[os, sets, tables, algorithm, strutils]
from std/strutils import nil
import ../core
import ../lib/[common, print]
import ./[store, util]

const help = """
bl assemble [--store:PATH] [--into PATH]

Materializes chunked trees. Reads values in any order: chunks are held
in one store, manifests in another, and a manifest is kept whether or
not what it names has arrived. The manifests nothing else names are
the roots.

A file manifest becomes a file, a dir manifest a directory, and the
names come from each manifest's own {name: ...}.

  bl file ~/src | bl assemble --into ~/dst

Trees are laid down as they complete, not when the input ends, so a
pipe that never closes still gets acted on:

  bl listen | bl assemble --into ~/dst

A root is laid down only once everything under it is present, and only
after the stream has gone quiet for a moment -- a burst still arriving
is not yet a thing to call complete. What is still missing is left
alone rather than half-written, so a transfer that arrives in pieces
finishes itself.

Options:
  --into PATH     where the roots land. A lone file manifest may go to
                  stdout instead.
  --store PATH    where to hold what arrives (default ~/.bl/store)
  --every:MS      how long a quiet counts as settled (default 500)
"""

type Stores = object
  chunks: Store
  manifests: Store

proc fail(msg: string) =
  quit "assemble: " & msg

func namePart(info: Option[BlFileInfo]): string =
  if info.isSome and info.get.name.isSome:
    info.get.name.get
  else:
    ""

proc safeName(n: string): string =
  ## Names arrive off the wire and become path segments. Anything that
  ## could climb out of the directory we were pointed at is refused
  ## rather than sanitized: a tree that cannot be laid down honestly
  ## should not be laid down at all.
  if n.len == 0:
    fail "a manifest has no name to land under"
  if n == "." or n == ".." or n.contains('/') or n.contains('\\') or n.contains('\0'):
    fail "unspeakable name in a manifest: " & n
  n

proc fetch(s: Store, d: Digest): Option[Value] =
  let raw = s.load(d)
  if raw.isNone:
    return none Value
  try:
    some decode(raw.get)
  except DecodeError as e:
    fail "stored value won't decode: " & e.msg
    none Value

# ================ WHAT ARRIVED ================

type Arrivals = object
  ## What this run has been told about. Names are kept whole rather than
  ## reduced to their bytes: a digest says which algo made it, and
  ## dropping that would send the lookup to the wrong shelf.
  held: Table[seq[byte], Digest] ## manifests that came past
  named: HashSet[seq[byte]] ## manifests some dir names

proc take(st: Stores, a: var Arrivals, v: Value) =
  ## One value onto its shelf. Chunks and manifests are told apart by
  ## what they are, never by when they showed up.
  if fromValue(v, Chunk).isSome:
    discard st.chunks.put(v)
    return

  let dm = fromValue(v, DirManifest)
  if dm.isSome:
    let d = st.manifests.put(v)
    a.held[d.hash] = d
    for child in dm.get.entries:
      a.named.incl child.hash
    return

  if fromValue(v, FileManifest).isSome:
    let d = st.manifests.put(v)
    a.held[d.hash] = d
    return

  # anything else in the stream is somebody else's business

proc rootsOf(a: Arrivals): seq[Digest] =
  ## The manifests nothing else this run mentioned names. Asking it of
  ## what arrived, rather than of everything the store has ever held,
  ## keeps an old tree on the shelf from being laid down again.
  for h, d in a.held:
    if h notin a.named:
      result.add d
  result.sort(
    proc(a, b: Digest): int =
      cmp(toValue a, toValue b)
  )

# ================ WHAT IS STILL OUT ================

proc missing(st: Stores, d: Digest, gaps: var seq[string]) =
  ## Walks what a name stands on, collecting whatever the stores can't
  ## answer for. Nothing is written while this is asking.
  let v = fetch(st.manifests, d)
  if v.isNone:
    gaps.add "manifest " & $toValue(d)
    return

  let fm = fromValue(v.get, FileManifest)
  if fm.isSome:
    for leaf in fm.get.leaves:
      if st.chunks.load(leaf).isNone:
        gaps.add "chunk " & $toValue(leaf)
    return

  let dm = fromValue(v.get, DirManifest)
  if dm.isSome:
    for child in dm.get.entries:
      missing(st, child, gaps)
    return

  gaps.add $toValue(d) & " names neither a file nor a dir manifest"

# ================ LAYING IT DOWN ================

proc writeChunks(st: Stores, m: FileManifest, dest: File) =
  ## Chunks in the order the manifest names them, checking as it goes
  ## that each one names the chunk actually before it -- the chain
  ## earning its place in the record. A first chunk that names
  ## something, or a later one that names the wrong thing, means the
  ## manifest and the chunks disagree about what this file is.
  var prev = none Digest
  for d in m.leaves:
    let raw = fetch(st.chunks, d)
    if raw.isNone:
      fail "the store doesn't hold " & $toValue(d)
    let c = fromValue(raw.get, Chunk)
    if c.isNone:
      fail $toValue(d) & " names something that isn't a chunk"
    let chunk = c.get
    if chunk.prev.isNone != prev.isNone or
        (prev.isSome and toValue(chunk.prev.get) != toValue(prev.get)):
      fail "chunk out of place: " & $toValue(d) & " doesn't follow what it should"
    if chunk.bytes.len > 0:
      if dest.writeBuffer(addr chunk.bytes[0], chunk.bytes.len) != chunk.bytes.len:
        fail "short write"
    prev = some d

proc materialize(st: Stores, d: Digest, into: string) =
  let v = fetch(st.manifests, d)
  if v.isNone:
    fail "the store doesn't hold " & $toValue(d)

  let fm = fromValue(v.get, FileManifest)
  if fm.isSome:
    let f = open(into / safeName(namePart(fm.get.info)), fmWrite)
    defer:
      f.close()
    writeChunks(st, fm.get, f)
    return

  let dm = fromValue(v.get, DirManifest)
  if dm.isSome:
    let here = into / safeName(namePart(dm.get.info))
    createDir here
    for child in dm.get.entries:
      materialize(st, child, here)
    return

  fail $toValue(d) & " names neither a file nor a dir manifest"

# ================ THE VERB ================

proc run*(args: seq[string]) =
  var
    root = defaultStoreRoot()
    into = ""
    every = 500
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "store":
        if val == "":
          quit "--store wants a path"
        root = val
      of "into":
        if val == "":
          quit "--into wants a path"
        into = val
      of "every":
        try:
          every = strutils.parseInt(val)
        except ValueError:
          quit "--every wants milliseconds, got: " & val
        if every < 1:
          quit "--every must be at least 1ms"
      else:
        quit "unknown assemble option: " & key & "\n\n" & help
    else:
      quit "assemble takes no arguments\n\n" & help

  let st = Stores(
    chunks: openStore(root / "chunks"), manifests: openStore(root / "manifests")
  )
  var
    arrivals = Arrivals()
    laid: HashSet[seq[byte]]

  proc sweep() =
    ## What has arrived a whole tree for, laid down once.
    for r in arrivals.rootsOf():
      if r.hash in laid:
        continue
      var gaps: seq[string]
      missing(st, r, gaps)
      if gaps.len > 0:
        continue # not all here yet; a later sweep will find it
      laid.incl r.hash
      if into == "":
        let v = fetch(st.manifests, r)
        let fm = fromValue(v.get, FileManifest)
        if fm.isNone:
          fail "a dir manifest needs somewhere to land -- pass --into PATH"
        writeChunks(st, fm.get, stdout)
        stdout.flushFile()
      else:
        createDir into
        materialize(st, r, into)
        stderr.writeLine "-- laid down " & $toValue(r)

  eachValueTicking(
    stdin,
    proc(v: Value) =
      st.take(arrivals, v)
    ,
    every,
    sweep,
  )

  if laid.len == 0:
    fail "nothing arrived that completes a tree"
