##[
The matcher is built by a Nim procedure over a network and explicit input
and output cells. There is no distinguished main cell. Construction walks
the pattern once and wires a sequence of checks; execution extends the
bindings of each subject that passes those checks.

A candidate keeps its subject and bindings together, so separate attempts
never share an assignment. Candidate cells retain distinct partial results.
A batch of candidates is one contribution, and merge reports progress only
when it retains a new candidate. Empty batches make no progress.

Each check has an immutable configuration cell and a candidate input. One
binary propagator implements all checks, with no captured network reference.
Configuration cells ignore contributions. The builder groups literal
subtrees into equality checks and decomposes frames containing holes into
shape checks followed by member checks. Paths select members of the original
subject, so intermediate cells need no traversal stack or copied subtrees.

Matching is exact in kind, mark and width. Holes are explicitly named nodes
and bind any node, including nil, marked nodes and live objects. Live objects
are never reified. Repeated holes require equal nodes. Dict keys and set
members must be literal; searching for bindings among unordered members is
outside this example. A hole can still capture a whole dict or set.
]##

import tinybl/[micro, prop, text]

type
  Binding = tuple[hole, value: Node]

  Candidate = object
    subject: Node
    bindings: seq[Binding]

  Check = object
    path: seq[int]
    case
    of Capture:
      hole: Node
    of Literal:
      expected: Node
    of FrameCheck:
      kind: Kind
      mark: bool
      width: int

  State = object
    case
    of Candidates:
      candidates: seq[Candidate]
    of Configuration:
      check: Check

  Info = object
    case
    of AddCandidates:
      candidates: seq[Candidate]

  MatchNetwork = Network[State, Info]

proc merge(state: var State, info: Info): bool =
  case state
  of Candidates(held):
    case info
    of AddCandidates(incoming):
      for candidate in incoming:
        if candidate notin held:
          held.add candidate
          result = true
  of Configuration:
    discard

func select(subject: Node, path: openArray[int]): Option[Node] =
  var current = subject
  for i in path:
    case current
    of Bound:
      return none(Node)
    of Plain(value):
      if not value.isFrame or i >= value.len:
        return none(Node)
      current = value.nth(i)
  some(current)

func extend(check: Check, candidate: Candidate): Option[Candidate] =
  let selected = select(candidate.subject, check.path)
  if selected.isNone:
    return none(Candidate)
  let node = selected.get
  case check
  of Capture(hole):
    for binding in candidate.bindings:
      if binding.hole == hole:
        return if binding.value == node: some(candidate) else: none(Candidate)
    var more = candidate
    more.bindings.add (hole, node)
    some(more)
  of Literal(expected):
    if node == expected: some(candidate) else: none(Candidate)
  of FrameCheck(kind, mark, width):
    case node
    of Plain(value):
      if value.kind == kind and value.mark == mark and value.len == width:
        some(candidate)
      else:
        none(Candidate)
    of Bound:
      none(Candidate)

func advance(config, input: State): Info =
  var batch: seq[Candidate]
  case config
  of Configuration(check):
    case input
    of Candidates(candidates):
      for candidate in candidates:
        let extended = extend(check, candidate)
        if extended.isSome:
          batch.add extended.get
    of Configuration:
      discard
  of Candidates:
    discard
  AddCandidates(candidates: batch)

func forward(input: State): Info =
  case input
  of Candidates(candidates): AddCandidates(candidates: candidates)
  of Configuration: AddCandidates(candidates: @[])

func containsHole(pattern: Node, holes: openArray[Node]): bool =
  if pattern in holes:
    return true
  case pattern
  of Plain(value):
    for member in value.members:
      if containsHole(member, holes):
        return true
  of Bound:
    discard

proc validate(pattern: Node, holes: openArray[Node]) =
  if pattern in holes:
    return
  case pattern
  of Plain(value):
    for i in 0 ..< value.len:
      let member = value.nth(i)
      if value.kind == bSet or (value.kind == bDict and i mod 2 == 0):
        if containsHole(member, holes):
          raise newException(BasslineError, "holes in dict keys or set members are unsupported")
      else:
        validate(member, holes)
  of Bound:
    discard

proc build(net: var MatchNetwork, p: BinaryP, input: Cell,
           pattern: Node, holes: openArray[Node], path: seq[int]): Cell =
  let check =
    if pattern in holes:
      Capture(path: path, hole: pattern)
    elif not containsHole(pattern, holes):
      Literal(path: path, expected: pattern)
    else:
      let value = pattern.asValue
      FrameCheck(path: path, kind: value.kind, mark: value.mark, width: value.len)
  let config = net.cell(Configuration(check: check))
  result = net.cell()
  discard net.relate(p, config, input, result)
  case check
  of FrameCheck:
    let value = pattern.asValue
    for i in 0 ..< value.len:
      result = build(net, p, result, value.nth(i), holes, path & @[i])
  else:
    discard

proc matchPattern(net: var MatchNetwork, input, output: Cell,
                  pattern: Node, holes: openArray[Node]) =
  validate(pattern, holes)
  let checking = net.def advance
  let finishing = net.def forward
  let last = build(net, checking, input, pattern, holes, @[])
  discard net.relate(finishing, last, output)

proc submit(net: var MatchNetwork, input: Cell,
            subjects: varargs[Node]): bool {.discardable.} =
  var batch: seq[Candidate]
  for subject in subjects:
    batch.add Candidate(subject: subject)
  net.put(input, AddCandidates(candidates: batch))

func answers(net: MatchNetwork, output: Cell): seq[Candidate] =
  case net[output]
  of Candidates(candidates): candidates
  of Configuration: @[]

proc show(net: MatchNetwork, name: string, output: Cell) =
  var rows: seq[Node]
  for candidate in net.answers(output):
    var bindings: seq[(Node, Node)]
    for binding in candidate.bindings:
      bindings.add (binding.hole, binding.value)
    rows.add Rec(@[candidate.subject, Dict(bindings)])
  echo Rec(@[Sym("matches"), Sym(name), List(rows)])

when isMainModule:
  proc node(s: string): Node = Value.parse(s).toNode

  var net = initNetwork(merge)
  net.cells subjects, pairs, nested, dicts, marked, literal
  let x = Sym("X")
  let y = Sym("Y")

  matchPattern(net, subjects, pairs, node("(pair X X)"), [x])
  matchPattern(net, subjects, nested, node("(wrap [X (pair X Y)])"), [x, y])
  matchPattern(net, subjects, dicts, node("{k: X}"), [x])
  matchPattern(net, subjects, marked, node("!(pair X X)"), [x])
  matchPattern(net, subjects, literal, node("(pair 7 7)"), [])

  net.submit(subjects,
    node("(pair 7 7)"), node("(pair 7 8)"), node("(pair nil nil)"),
    node("!(pair 7 7)"), node("(pair 7)"),
    node("(wrap [7 (pair 7 nil)])"), node("(wrap [7 (pair 8 nil)])"),
    node("{k: 42}"))
  net.run()
  doAssert net.answers(pairs).len == 2
  doAssert net.answers(nested).len == 1
  doAssert net.answers(dicts).len == 1
  doAssert net.answers(marked).len == 1
  doAssert net.answers(literal).len == 1
  doAssert net.answers(literal)[0].bindings.len == 0
  net.show("pairs", pairs)
  net.show("nested", nested)
  net.show("dicts", dicts)
  net.show("marked", marked)
  net.show("literal", literal)

  net.submit(subjects, node("(pair 9 9)"))
  net.run()
  doAssert net.answers(pairs).len == 3
  doAssert not net.submit(subjects, node("(pair 9 9)"))
  doAssert net.run() == 0
  net.show("later", pairs)

  type Token = ref object of Live
  method reified(self: Token): Value = Sym("token").toValue

  let token = Token().toNode
  let other = Token().toNode
  net.submit(subjects, Rec(@[Sym("pair"), token, token]),
                       Rec(@[Sym("pair"), token, other]))
  net.run()
  doAssert net.answers(pairs).len == 4
  let captured = net.answers(pairs)[^1].bindings[0].value
  doAssert captured.isBound and captured == token
  echo Rec(@[Sym("opaque-child-preserved")])

