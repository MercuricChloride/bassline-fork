##[
  hidden: a value by a digest of its own tree, so that whoever holds it
  can show any part, with nothing else, to a stranger who holds only
  the digest, or a signature over it.

    (hidden D)                        a value, by its root node's digest
    (leaf V)                          a node: V, whole
    (leaf V SALT)                     a node: V, whole, blinded; SALT bytes
    (KIND (root N D))                 a node: a frame of KIND, hidden by
                                      its parts, whose nodes run to
                                      (root N D); marked as the frame is
    (shown (hidden D) [STEP …] NODE)  down these steps from D sits NODE
    (KIND N I [SIB …])                a step: a frame of KIND with N
                                      parts, at part I, SIB the subtree
                                      digests off the way; marked as
                                      the frame is

  The tree mirrors the value. A part hidden whole is a leaf, and its
  node is the digest of (leaf V): for an unsalted V that is the node
  evidence makes of a leaf, so a set hidden by its parts, its members
  whole, has exactly the tree an opening is checked against. A frame
  hidden by its parts has for its node the digest of (KIND (root N D)),
  the evidence root over its parts' nodes in `parts` order: a record's
  head first, a dict's key before its value, a set's members by CE.
  KIND is one of list, record, dict and set, and the node record is
  marked when the frame is, so the mark is in what is hashed.

  Because a frame's node is computed from its parts' nodes, there is
  at most one value under a digest by construction: a part shown on its
  own and the same part shown inside its parent can't disagree. A flat
  tree over a walk of the value, with the position in each leaf, would
  commit to each part once per ancestor and tie none of them together.
  That the tree is a value's at all is the hider's premise, as a set's
  order is an opening's: a dict node's count is even, a set's run is its
  members in CE order, each once; a shown doesn't tell, and a reader
  that must know audits the whole once.

  A shown is checked with the digest alone, in the sum of log N over
  the frames it passes through, never a width: the checker digests the
  node, and up each step rebuilds the run root from the node, its place
  and the siblings, wraps it as (KIND (root N R)) and digests again, and
  asks whether it has reached D. The counts fix every width, so a shown
  says what sits at a place and that nothing else sits there.

  A salt blinds a leaf whose value is guessable: a sibling digest in a
  proof of its neighbour is otherwise a dictionary attack on a small
  field. The one who hides keeps the salts and hands one over only in
  the shown that reveals its leaf. Frames need none once their leaves
  are blinded; a frame with no parts is hidden whole, so its node is not
  a constant. Which frames are hidden by their parts, and which leaves
  are salted, is the hider's choice, part by part, and the steps say;
  the checker is indifferent. A set whose members are hidden whole and
  unsalted has for its run exactly the tree evidence makes over its
  members, so an opening of a range of it checks against the (root N D)
  a shown reveals for the set, under the one signature.

  What a key signs is (hidden D). A reader opens the signature, checks
  each shown against D, and takes the parts it was shown; several shown
  against one D are several parts of one value. Which parts to ask for
  and what they entail is the reader's own: `way` reads the steps down,
  so a dict's key is told from its value and a record's head from its
  fields by the place in each frame.
]##

import std/[options, sequtils, sysrand]
import ../[core, mold, queries]
import ./evidence
export mold

refuseWith MoldError

moldable """{
  (struct hidden {exact (rep record)} (digest value))
  (struct shown {exact (rep record)} (hidden hidden) (steps [any]) (node any))
}"""

const
  SaltLen* = 32
  FrameKinds = {bList, bRec, bDict, bSet}

type
  Step* = object
    ## one frame on the way down: its kind and mark, how many parts, which
    ## one, and the subtree digests off the way. Spelled (KIND N I [SIB …])
    ## with the frame's kind for its head and the frame's mark on it, which
    ## no one moldable struct describes, so it is read by hand
    kind*: Kind
    mark*: bool
    count*, index*: int
    path*: seq[Value]

  Tree* = ref object
    ## a value hidden, kept by its hider: the node and, when hidden by its
    ## parts, the trees of the parts, so any of them can be shown
    node*: Value
    digest*: Value
    parts*: seq[Tree]

# ================ nodes ================

# a node is the digest of its preimage, evidence's nodeDigest; a part
# hidden whole has evidence's leaf for its preimage, so an unsalted
# leaf's node is evidence's leaf node by construction

proc leaf*(v: Value, salt: Value): Value =
  ## (leaf V SALT): the preimage of a part hidden whole and blinded
  bl"(leaf $v $salt)"

proc frame*(kind: Kind, mark: bool, root: Root): Value =
  ## (KIND (root N D)), marked as the frame is: the preimage of a frame
  ## hidden by its parts
  let head = sym($kind)
  bl("($head $root)", mark)

proc frameKind(v: Value): Option[Kind] =
  ## the frame kind an unmarked symbol names, if one
  if not v.isKind(bSym, unmarked): return none(Kind)
  let k = parseKind(v.text)
  if k.isSome and k.get in FrameKinds: k else: none(Kind)

proc leafOf*(node: Value): Option[Value] =
  ## the value a leaf node holds, if `node` reads as one
  matchValue node:
  of "(leaf $v)": some v
  of "(leaf $v $salt)":
    if salt.isKind(bBytes, unmarked): some v else: none(Value)
  else: none(Value)

proc frameOf*(node: Value): Option[tuple[kind: Kind, mark: bool, root: Root]] =
  ## the frame a node stands for, if `node` reads as one
  type Frame = tuple[kind: Kind, mark: bool, root: Root]
  matchValue node:
  of "($kind $root) {any-mark}":
    let (k, r) = (frameKind(kind), Root.maybeLoad(root))
    if k.isSome and r.isSome: some (k.get, node.mark, r.get) else: none(Frame)
  else: none(Frame)

proc readNode(node: Value) =
  guard leafOf(node).isSome or frameOf(node).isSome,
    "a node is (leaf V), (leaf V SALT) or (KIND (root N D))"

# ================ steps ================

proc toValue*(s: Step): Value =
  let (head, n, i, path) = (sym($s.kind), s.count, s.index, s.path)
  bl("($head $n $i $path)", s.mark)

proc count(v: Value): Option[int] =
  ## an unmarked count, if `v` is one
  if v.isKind(bNum, unmarked) and v.num.isInt and v.num.toInt >= 0:
    some v.num.toInt
  else: none(int)

proc stepOf*(v: Value): Option[Step] =
  ## the step `v` spells, if it reads as one: (KIND N I [SIB …]), marked
  ## as the frame is, I a place among N
  matchValue v:
  of "($kind $width $index [&path]) {any-mark}":
    let (k, n, i) = (frameKind(kind), count(width), count(index))
    if k.isSome and n.isSome and i.isSome and i.get < n.get:
      some Step(kind: k.get, mark: v.mark, count: n.get, index: i.get, path: path)
    else: none(Step)
  else: none(Step)

proc place*(s: Step): Value =
  ## the step without its siblings, (KIND N I) marked as the frame is:
  ## where a part sits, said without the proof
  let (head, n, i) = (sym($s.kind), s.count, s.index)
  bl("($head $n $i)", s.mark)

proc way*(s: Shown): seq[Step] =
  ## the way down, its steps read; refused where one doesn't read
  for v in s.steps:
    let st = stepOf(v)
    guard st.isSome, "a step is (KIND N I [SIB …]), I a place among N"
    result.add st.get

method afterLoad(self: Shown) =
  readNode(self.node)
  discard self.way

# ================ hiding ================

proc hasParts*(v: Value): bool =
  ## whether `v` is a frame with anything in it
  v.isKind(FrameKinds) and v.len > 0

func never*(v: Value): bool = false

proc hide*(v: Value, apart: (Value) -> bool = hasParts,
           salted: (Value) -> bool = never): Tree =
  ## `v` hidden: a frame for which `apart` holds by its parts, each hidden
  ## the same way, anything else whole, blinded by a fresh salt when
  ## `salted` holds of it. A frame with no parts is hidden whole whatever
  ## `apart` says. The members of a set that is to be opened are hidden
  ## whole and unsalted, since an opening reveals them anyway and checks
  ## against the tree over them as they are
  if v.hasParts and apart(v):
    let parts = v.parts.maps(hide(it, apart, salted)).toSeq
    let nodes = parts.mapIt(it.digest)
    let node = frame(v.kind, v.mark, Root(count: nodes.len, digest: treeRoot(nodes)))
    Tree(node: node, digest: nodeDigest(node), parts: parts)
  else:
    let node = if salted(v): leaf(v, bytes(urandom(SaltLen))) else: leaf(v)
    Tree(node: node, digest: nodeDigest(node))

proc hidden*(t: Tree): Hidden =
  ## (hidden D): the value by its root
  Hidden(digest: t.digest)

proc shown*(t: Tree, path: openArray[int]): Shown =
  ## the shown for the node down `path`, the places of parts from the root
  var steps: seq[Value]
  var at = t
  for i in path:
    guard at.parts.len > 0, "hidden whole: nothing inside it to show"
    guard i in 0 ..< at.parts.len, "no part at " & $i
    let f = frameOf(at.node).get
    steps.add Step(kind: f.kind, mark: f.mark, count: at.parts.len, index: i,
                   path: treePath(at.parts.mapIt(it.digest), i)).toValue
    at = at.parts[i]
  Shown(hidden: t.hidden, steps: steps, node: at.node)

# ================ checking ================

proc holds*(s: Shown): bool =
  ## whether the shown holds: from its node, up its steps, it reaches the
  ## digest of the hidden value. A step that doesn't read holds nothing
  var d = nodeDigest(s.node)
  for i in countdown(s.steps.high, 0):
    let st = stepOf(s.steps[i])
    if st.isNone: return false
    let r = rebuiltFrom(d, st.get.index, st.get.count, st.get.path)
    if r.isNone: return false
    d = nodeDigest(frame(st.get.kind, st.get.mark, Root(count: st.get.count, digest: r.get)))
  d == s.hidden.digest

proc part*(s: Shown): Option[Value] =
  ## the value shown, if the shown holds and its node is a leaf; a frame
  ## node shows only a frame's kind, mark and width, through `frameOf`
  if not s.holds: return none(Value)
  leafOf(s.node)

proc places*(s: Shown): Value =
  ## where the shown's node sits, as the list of its steps' places
  initList(s.way.mapIt(it.place))

proc depth*(s: Shown): int =
  ## how many frames the shown passes through
  s.steps.len
