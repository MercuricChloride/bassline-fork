## A value opened up to be worked on.
##
## A value is finished: its sets and dicts are sorted, nothing in them is
## repeated, a record has its head. Doing the marked values inside one
## passes through states that are not values: a key not yet done, two
## members that have become equal, a part taken out. A tree is the value
## as a draft, and `finish` reads the value it stands for.
##
## A node is a place, not a value. It holds a kind, a mark, and an atom or
## members, and what it holds can change while the place stays. So whoever
## holds a node holds whatever comes to stand there, and the root is a
## place like any other. Nothing is put into a place but contents: a
## value, or what another place holds. A loose node handed over is taken
## as it is. One that still stands somewhere is copied, and stays.
##
## A node keeps what it is and works out where it is. Its kind, its mark
## and its members are its own. Its `slot`, its place in the frame around
## it, its `region`, its place among the marks, and its `path` are read
## off the tree when asked, so none of them can be out of date. The
## finished value is kept until something under it changes.
##
## There are three sorts of rule, each kept in one place. What the slots
## rest on holds after every edit, and an edit that would break it is
## refused before anything has changed: a node is in one frame, a record
## has its head, a dict's members come as key and value. What rests on
## comparing values is left to `finish`: order, and members made equal,
## which are one member. Only a key given two different values is refused
## there. What has been edited since the last finish is the tree's own
## business.
##
## Four edits change a tree, and everything else is written with them.
## `splice` puts members where a run of a frame's members stood, and is
## the only way a frame's members change. `mark=` and `kind=` change what
## a node is over the same members. `replace` changes everything a place
## holds. `cut`, `insert` and `add` are splices.

import std/[algorithm, options]
import ../core

refuseWith BasslineError

const Frames = {bList, bRec, bDict, bSet}

type
  RegionKind* = enum
    rkGround   ## unmarked, with nothing marked above it
    rkCrown    ## marked, and marked all the way up to the root
    rkPocket   ## unmarked under something marked: material
    rkIsland   ## marked under something unmarked

  Slot* = enum
    sRoot      ## in nothing
    sItem      ## a list's member
    sHead      ## a record's first member
    sField     ## a record's member after its head
    sMember    ## a set's member
    sEntry     ## a dict's key and value together
    sKey       ## the first part of an entry
    sValue     ## the second part of an entry

  Shape = enum
    shAtom     ## a value with nothing inside it
    shFrame    ## a value with members
    shEntry    ## a dict's key and value together: a node, not a value

  NodeObj = object
    up {.cursor.}: Node
    case shape: Shape
    of shAtom:
      atom: Value            ## the value itself, its mark with it
    of shFrame:
      fkind: Kind
      fmark: bool
      members: seq[Node]     ## values, or for a dict its entries
      cache: Value           ## the value last finished
      stale: bool            ## something under here changed since
    of shEntry:
      pair: array[2, Node]   ## the key, then its value

  Node* = ref NodeObj

# ---------------------------------------------------------------------------
# What a node is

func isAtom*(self: Node): bool = self.shape == shAtom
func isFrame*(self: Node): bool = self.shape == shFrame
func isEntry*(self: Node): bool = self.shape == shEntry
  ## An entry is the one node that is not a value. It has no kind and no
  ## mark, and it is not finished, replaced or marked.

proc kind*(self: Node): Kind =
  case self.shape
  of shAtom: self.atom.kind
  of shFrame: self.fkind
  of shEntry: refuse "an entry is not a value and has no kind"

proc mark*(self: Node): bool =
  case self.shape
  of shAtom: self.atom.mark
  of shFrame: self.fmark
  of shEntry: refuse "an entry is not a value and has no mark"

proc isKind*(self: Node, kinds: set[Kind], mark = anyMark): bool =
  ## Whether `self` is a value of one of `kinds`, marked as asked. An
  ## entry is none.
  self.shape != shEntry and self.kind in kinds and (mark.isNone or mark.get == self.mark)

proc isKind*(self: Node, kind: Kind, mark = anyMark): bool = self.isKind({kind}, mark)

func dirty*(self: Node): bool =
  ## whether something under `self` changed since it was last finished
  self.shape == shFrame and self.stale

# ---------------------------------------------------------------------------
# Where a node stands

func parent*(self: Node): Node = self.up

func len*(self: Node): int =
  ## how many nodes stand directly in `self`: a frame's members, a dict's
  ## entries, an entry's two parts
  case self.shape
  of shAtom: 0
  of shFrame: self.members.len
  of shEntry: 2

proc children*(self: Node): seq[Node] =
  ## The nodes directly in `self`, a dict's as entries. A fresh sequence,
  ## so it may be walked while the tree is edited.
  case self.shape
  of shAtom: @[]
  of shFrame: self.members
  of shEntry: @(self.pair)

proc `[]`*[Idx](self: Node, p: varargs[Idx]): Node =
  ## the node reached from `self` by the positions `p`, one step each
  result = self
  for i in p:
    result = case result.shape
      of shFrame: result.members[int i]
      of shEntry: result.pair[int i]
      of shAtom: refuse "an atom has nothing inside it"

proc index(self: Node): int =
  ## self's position among what its parent holds
  if self.up.shape == shEntry: (if self.up.pair[0] == self: 0 else: 1)
  else: self.up.members.find(self)

proc path*(self: Node): seq[int] =
  ## Where a node stands from the root, by position: `root[n.path]` is
  ## `n`. A dict's entry is one step, its key and value 0 and 1 under it.
  var at = self
  while not at.up.isNil:
    result.add at.index
    at = at.up
  result.reverse

proc frame*(self: Node): Node =
  ## The frame a node is a part of, nil for the root. A key or a value is
  ## a part of its dict: the entry between them is passed through.
  result = self.up
  if not result.isNil and result.shape == shEntry: result = result.up

proc parts*(self: Node): seq[Node] =
  ## The values directly inside `self`, a dict's as keys and values in
  ## turn. A fresh sequence, so it may be walked while the tree is edited.
  case self.shape
  of shAtom: discard
  of shEntry: result = @(self.pair)
  of shFrame:
    for m in self.members:
      if m.shape == shEntry: result.add m.pair else: result.add m

proc slot*(self: Node): Slot =
  ## Self's place in what is around it, read off the tree as it stands.
  let p = self.up
  if p.isNil: sRoot
  elif self.shape == shEntry: sEntry
  elif p.shape == shEntry: (if p.pair[0] == self: sKey else: sValue)
  else:
    case p.fkind
    of bList: sItem
    of bRec: (if p.members[0] == self: sHead else: sField)
    else: sMember

proc region*(self: Node): RegionKind =
  ## A node is in the region of the frame around it until the mark
  ## changes. An entry has no mark of its own and is where its dict is.
  if self.shape == shEntry: return self.up.region
  let
    around = self.frame
    m = self.mark
  if around.isNil:
    if m: rkCrown else: rkGround
  elif m == around.mark: around.region
  elif m: rkIsland
  else: rkPocket

proc isUnder(self, other: Node): bool =
  ## whether `self` is somewhere inside `other`
  var at = self.up
  while not at.isNil:
    if at == other: return true
    at = at.up

iterator walk*(self: Node): Node {.closure.} =
  ## Every value at and under `self`, a frame before its parts. A node's
  ## parts are read when the walk comes back from it, so a node edited
  ## while it is visited is walked as what it has become, and members put
  ## in beside it are not visited.
  yield self
  for part in self.parts:
    for each in part.walk:
      yield each

iterator regions*(self: Node, s: set[RegionKind]): Node =
  for each in self.walk:
    if each.region in s: 
      yield each

func atomValue*(self: Node): lent Value =
  self.atom

# ---------------------------------------------------------------------------
# Opening a value

proc entryOf(key, value: Node): Node =
  result = Node(shape: shEntry, pair: [key, value])
  key.up = result
  value.up = result

proc toNode*(v: sink Value): Node =
  ## `v` as a tree of its own, every part of it a node.
  if v.kind notin Frames: return Node(shape: shAtom, atom: v)
  result = Node(shape: shFrame, fkind: v.kind, fmark: v.mark, cache: v)
  template hold(n: Node) =
    let child = n
    child.up = result
    result.members.add child
  case result.fkind
  of bList, bRec:
    for m in result.cache.items: hold toNode(m)
  of bSet:
    for m in result.cache.els: hold toNode(m)
  else:
    for k, val in result.cache.dict: hold entryOf(toNode(k), toNode(val))

proc toNodes*(vals: sink seq[Value]): seq[Node] =
  result = newSeq[Node](vals.len)
  for i, each in vals:
    result[i] = each.toNode

proc copy*(self: Node): Node =
  ## A loose node holding what `self` holds, edits not yet finished among
  ## them. `self` is left as it is.
  case self.shape
  of shAtom: result = Node(shape: shAtom, atom: self.atom)
  of shEntry: result = entryOf(self.pair[0].copy, self.pair[1].copy)
  of shFrame:
    result = Node(shape: shFrame, fkind: self.fkind, fmark: self.fmark,
                  cache: self.cache, stale: self.stale)
    for m in self.members:
      let child = m.copy
      child.up = result
      result.members.add child

# ---------------------------------------------------------------------------
# The four edits

proc touch(self: Node) =
  ## What stands at or under `self` changed: every frame from it up is
  ## built again at the next finish. Above a frame already marked so,
  ## every frame is.
  var at = self
  while not at.isNil:
    if at.shape == shFrame:
      if at.stale: return
      at.stale = true
    at = at.up

proc loose(self, node: Node): Node =
  ## `node` as something that can be put at or under `self`: itself when
  ## it stands nowhere, a copy when it still stands somewhere
  guard node.shape != shEntry, "an entry is not a value to put in"
  if node.up.isNil and node != self and not self.isUnder(node): node else: node.copy

proc seated(self: Node, values: seq[Node]): seq[Node] =
  ## `values` as members of `self`: themselves, or for a dict paired into
  ## entries
  if self.fkind == bDict:
    for i in countup(0, values.high, 2):
      let e = entryOf(values[i], values[i + 1])
      e.up = self
      result.add e
  else:
    for v in values:
      v.up = self
      result.add v

proc put(self: Node, at: Slice[int], values: seq[Node]) =
  ## `values`, loose value nodes, where the members `at` stood. Every
  ## check comes before the first change.
  guard self.shape == shFrame, "only a frame has members to splice"
  let n = self.members.len
  guard at.a in 0 .. n and at.b in at.a - 1 ..< n,
    "no members " & $at.a & " to " & $at.b & " among " & $n & ", at " & $self.path
  let gone = at.b - at.a + 1
  case self.fkind
  of bDict:
    guard values.len mod 2 == 0,
      "a dict takes keys and values in pairs, and one is left over, at " & $self.path
  of bRec:
    guard n - gone + values.len > 0, "a record needs a head, at " & $self.path
    guard not (at.a == 0 and gone > 0 and values.len == 0),
      "a record keeps its head, since the field after it would become the head " &
      "without anyone having said so, at " & $self.path
  else: discard
  let
    before = self.members[0 ..< at.a]
    after = self.members[at.b + 1 .. ^1]
  for i in at.a .. at.b: self.members[i].up = nil
  self.members = before & self.seated(values) & after
  self.touch

proc splice*(self: Node, at: Slice[int], members: varargs[Value]) =
  ## `members` where the members `at` of the frame `self` stood: none
  ## takes them out, an empty run puts more in. A dict counts by entry and
  ## takes keys and values in turn. A record's first member is its head,
  ## so taking the head out needs something given in its place.
  var values: seq[Node]
  for v in members: values.add toNode(v)
  self.put(at, values)

proc splice*(self: Node, at: Slice[int], members: varargs[Node]) =
  ## The same with nodes. A loose node is put in as it is, the node it
  ## was. One that still stands somewhere is copied.
  var values: seq[Node]
  for m in members:
    values.add(if m in values: m.copy else: self.loose(m))
  self.put(at, values)

proc insert*(self: Node, at: int, members: varargs[Value]) = self.splice(at ..< at, members)
proc insert*(self: Node, at: int, members: varargs[Node]) = self.splice(at ..< at, members)
proc add*(self: Node, members: varargs[Value]) = self.splice(self.len ..< self.len, members)
proc add*(self: Node, members: varargs[Node]) = self.splice(self.len ..< self.len, members)

proc cut*(self: Node) =
  ## `self` out of the frame it is in. A key or a value takes its entry
  ## with it.
  case self.slot
  of sRoot: refuse "the root is in nothing it could be cut from"
  of sKey, sValue: self.up.cut
  else:
    let i = self.index
    self.up.put(i .. i, @[])

proc splice*(self: Node, values: varargs[Value]) =
  ## `values` where `self` stood, each a member in its own right.
  case self.slot
  of sRoot: refuse "nothing is spliced in for the root"
  of sKey, sValue, sEntry:
    refuse "a dict's members are spliced on the dict, as keys and values, at " & $self.path
  else:
    let i = self.index
    self.up.splice(i .. i, values)

proc `mark=`*(self: Node, mark: bool) =
  if self.mark == mark: return
  case self.shape
  of shAtom: self.atom.mark = mark
  of shFrame:
    self.fmark = mark
    self.cache.mark = mark   # the mark is the handle's, so a value kept is right again
  of shEntry: discard
  self.up.touch

proc `kind=`*(self: Node, kind: Kind) =
  ## `self` as a frame of `kind` over the members and with the mark it
  ## has: a record as a list, a list as a set. Refused where the members
  ## cannot be that kind's: a record with none, a dict with one left over.
  ## Out of a set or dict the members come in the order the draft has
  ## them, a dict's as keys and values in turn.
  guard self.shape == shFrame, "only a frame becomes another kind of frame"
  guard kind in Frames, "not a kind of frame: " & $kind
  if self.fkind == kind: return
  let values = self.parts
  guard kind != bRec or values.len > 0, "a record needs a head, at " & $self.path
  guard kind != bDict or values.len mod 2 == 0,
    "a dict takes keys and values in pairs, and one is left over, at " & $self.path
  self.fkind = kind
  self.members = self.seated(values)
  self.touch

proc hold(self, donor: Node) =
  ## `self` comes to hold what `donor` holds. `donor`, a loose node or one
  ## inside `self`, is used up and left holding nil.
  let up = self.up
  var contents: NodeObj
  case donor.shape
  of shAtom: contents = NodeObj(shape: shAtom, atom: donor.atom)
  of shFrame:
    contents = NodeObj(shape: shFrame, fkind: donor.fkind, fmark: donor.fmark,
                       members: move donor.members, cache: donor.cache, stale: donor.stale)
  of shEntry: refuse "an entry is not a value to put in"
  for c in self.children: c.up = nil
  self[] = contents
  self.up = up
  if self.shape == shFrame:
    for m in self.members: m.up = self
  donor[] = NodeObj(shape: shAtom, atom: null())

proc replace*(self: Node, v: sink Value) =
  ## `v` where `self` stood. The node stays the node it was, so whoever
  ## holds it holds the new value, and the root is replaced like any other.
  guard self.shape != shEntry, "an entry is not a value to replace"
  self.hold toNode(v)
  self.up.touch

proc replace*(self, node: Node) =
  ## What `node` holds, where `self` stood. A loose node is used up. A
  ## part of `self` is lifted into the place of the frame it was in. A
  ## node that stands anywhere else is copied and stays.
  guard self.shape != shEntry, "an entry is not a value to replace"
  if node == self: return
  self.hold(if node.isUnder(self): node else: self.loose(node))
  self.up.touch

# ---------------------------------------------------------------------------
# Finishing

proc finish*(self: Node): Value =
  ## The value the tree at `self` stands for now. Only what was edited is
  ## built again, and the tree is left the draft it was. Members of a set
  ## made equal are one member, and so is a key given the same value
  ## twice. A key given two different values is refused.
  case self.shape
  of shEntry: refuse "an entry is not a value to finish"
  of shAtom: self.atom
  of shFrame:
    if self.stale:
      case self.fkind
      of bList, bRec:
        var members: seq[Value]
        for m in self.members: members.add m.finish
        self.cache = if self.fkind == bList: initList(members, self.fmark)
                     else: initRec(members, self.fmark)
      of bSet:
        let els = newBSet()
        for m in self.members: els.incl m.finish
        self.cache = initSet(els, self.fmark)
      else:
        let dict = newBDict()
        for e in self.members:
          let
            k = e.pair[0].finish
            v = e.pair[1].finish
          if k in dict:
            guard v == dict[k],
              "a dict made with two values for one key, " & $k & ", at " & $self.path
          else: dict[k] = v
        self.cache = initDict(dict, self.fmark)
      self.stale = false
    self.cache

when isMainModule:
  let
    root = toNode rv"""{
      [a! b]
      a!
      !(log bar)
      [c d set! mark!]
    }"""

  for each in root.walk:
    if not each.isKind(bSym, marked): continue
    case each.finish.text
    of "a":
      echo "path: ", each.path
      echo "at path: ", root[each.path].finish
      each.splice readDocument("foo bar baz")
    of "mark":
      let p = each.frame
      each.cut
      p.mark = true
    of "set":
      let p = each.frame
      each.cut
      p.kind = bSet
    else: discard

  echo root.finish
