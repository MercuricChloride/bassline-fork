## The library an image boots with past its core: numbers, comparing,
## values, a loop, and introspection, each a native object in the root,
## then boot.bl, the mezzanine and the manual, written in the language and
## evaluated in the root.
##
## A doc is a Doc layer holding text or a dict. Text whose first line is a
## form, `(add N …)`, has that line as its usage and the rest as its
## summary, and any other text is all summary. A dict may hold `usage`,
## `summary` and `body` texts and `see`, a list of names. `man` renders
## either.

import std/[algorithm, strutils, unicode]
import core
export core

refuseWith BasslineError

useValue Val

{.push raises: [BasslineError].}

let sTrue* = headSym"true"

proc holds(a: Val): Val =
  ## what a comparison that holds answers: its first argument, or `true`
  ## when that is nil, since nil is the only false
  if a.kind == bNil: sTrue else: a

proc num(v, msg: Val): BNum =
  guard v.kind == bNum, "not a number: " & $v & " in " & $msg
  v.num

proc numVal(n: BNum): Val = Val.buildAtom($n, bNum, false)

template arith(msg: Val, body: untyped): BNum =
  ## body's number, whatever BNum's wide arithmetic raises said as a refusal
  var answer: BNum
  try:
    answer = body
  except BasslineError as e:
    raise e
  except Exception as e:
    refuse e.msg & " in " & $msg
  answer

proc textVal(s: string): Val = Val.buildAtom(s, bText, false)

proc textOf*(v: Val): string =
  ## text and symbols as they read, anything else in text syntax
  if v.kind in {bText, bSym}: v.text else: $v

proc listOf(members: seq[Val]): Val = Val.buildFrame(members, bList, false)

proc members(v, msg: Val): seq[Val] =
  guard v.kind in {bList, bRec}, "not a list or record: " & $v & " in " & $msg
  for each in v.children:
    result.add each

proc arity(a: seq[Val], n: int, msg: Val, usage: string) =
  guard a.len == n, usage & ": " & $msg

# ================
# Numbers
# ================

proc addN(msg, self, sender: Val): Val {.native: "add".} =
  ## (add N …)
  ## The sum of the numbers, 0 for none.
  var total: BNum = 0
  for each in msg.args(sender):
    total = arith(msg, total + each.num(msg))
  numVal(total)

proc subN(msg, self, sender: Val): Val {.native: "sub".} =
  ## (sub N M …)
  ## N less each M, or N negated when it stands alone.
  let a = msg.args(sender)
  guard a.len > 0, "(sub N M …): " & $msg
  if a.len == 1:
    return numVal(arith(msg, 0.toNum - a[0].num(msg)))
  var total = a[0].num(msg)
  for i in 1 ..< a.len:
    total = arith(msg, total - a[i].num(msg))
  numVal(total)

proc mulN(msg, self, sender: Val): Val {.native: "mul".} =
  ## (mul N …)
  ## The product of the numbers, 1 for none.
  var total: BNum = 1
  for each in msg.args(sender):
    total = arith(msg, total * each.num(msg))
  numVal(total)

proc divN(msg, self, sender: Val): Val {.native: "div".} =
  ## (div N M)
  ## N divided by M, rounded toward zero. Dividing by 0 refuses.
  let a = msg.args(sender)
  a.arity(2, msg, "(div N M)")
  let d = a[1].num(msg)
  guard d != 0.toNum, "division by zero: " & $msg
  numVal(arith(msg, a[0].num(msg) div d))

proc modN(msg, self, sender: Val): Val {.native: "mod".} =
  ## (mod N M)
  ## What is left of N after dividing by M, with N's sign. M of 0 refuses.
  let a = msg.args(sender)
  a.arity(2, msg, "(mod N M)")
  let d = a[1].num(msg)
  guard d != 0.toNum, "division by zero: " & $msg
  numVal(arith(msg, a[0].num(msg) mod d))

# ================
# Comparing
# ================

proc order(a, b: Val): int =
  ## numbers by size, and anything else in CE order
  if a.kind == bNum and b.kind == bNum: cmp(a.num, b.num) else: cmp(a, b)

template comparing(msg, sender: Val, test: untyped): Val =
  let a {.inject.} = msg.args(sender)
  guard a.len == 2, "takes two values: " & $msg
  let c {.inject.} = order(a[0], a[1])
  if test: holds(a[0]) else: null

proc eqN(msg, self, sender: Val): Val {.native: "eq".} =
  ## (eq A B)
  ## A when B equals it, and nil otherwise. A nil A that holds answers true.
  comparing(msg, sender, a[0] == a[1])

proc neN(msg, self, sender: Val): Val {.native: "ne".} =
  ## (ne A B)
  ## A when B differs from it, and nil otherwise.
  comparing(msg, sender, a[0] != a[1])

proc ltN(msg, self, sender: Val): Val {.native: "lt".} =
  ## (lt A B)
  ## A when it comes before B, and nil otherwise. Numbers compare by size,
  ## anything else in CE order.
  comparing(msg, sender, c < 0)

proc leN(msg, self, sender: Val): Val {.native: "le".} =
  ## (le A B)
  ## A when it comes before B or equals it, and nil otherwise.
  comparing(msg, sender, c <= 0)

proc gtN(msg, self, sender: Val): Val {.native: "gt".} =
  ## (gt A B)
  ## A when it comes after B, and nil otherwise.
  comparing(msg, sender, c > 0)

proc geN(msg, self, sender: Val): Val {.native: "ge".} =
  ## (ge A B)
  ## A when it comes after B or equals it, and nil otherwise.
  comparing(msg, sender, c >= 0)

proc notN(msg, self, sender: Val): Val {.native: "not".} =
  ## (not X)
  ## The symbol true when X is nil, and nil otherwise. nil is the only false.
  let a = msg.args(sender)
  a.arity(1, msg, "(not X)")
  if a[0].kind == bNil: sTrue else: null

# ================
# Values
# ================

proc listN(msg, self, sender: Val): Val {.native: "list".} =
  ## (list X …)
  ## A list of the values.
  listOf(msg.args(sender))

proc recordN(msg, self, sender: Val): Val {.native: "record".} =
  ## (record HEAD X …)
  ## A record of the values, HEAD first.
  let a = msg.args(sender)
  guard a.len > 0, "a record has a head: " & $msg
  Val.buildFrame(a, bRec, false)

proc toRecordN(msg, self, sender: Val): Val {.native: "to-record".} =
  ## (to-record LIST)
  ## A record of LIST's members, so code can be built as a list and run.
  let a = msg.args(sender)
  a.arity(1, msg, "(to-record LIST)")
  let items = a[0].members(msg)
  guard items.len > 0, "a record has a head: " & $msg
  Val.buildFrame(items, bRec, false)

proc lenN(msg, self, sender: Val): Val {.native: "len".} =
  ## (len X)
  ## How many members a frame has, a dict counting its keys, how many
  ## characters a text or symbol has, how many bytes bytes have.
  let a = msg.args(sender)
  a.arity(1, msg, "(len X)")
  let v = a[0]
  let n =
    case v.kind
    of bList, bRec: v.len
    of bDict: v.dict.len
    of bSet: v.els.len
    of bText, bSym: v.text.runeLen
    of bBytes: v.bytes.len
    else: refuse "no length: " & $v & " in " & $msg
  numVal(n.toNum)

proc firstN(msg, self, sender: Val): Val {.native: "first".} =
  ## (first FRAME)
  ## A list's or record's first member, nil when it has none.
  let a = msg.args(sender)
  a.arity(1, msg, "(first FRAME)")
  let items = a[0].members(msg)
  if items.len == 0: null else: items[0]

proc restN(msg, self, sender: Val): Val {.native: "rest".} =
  ## (rest FRAME)
  ## A list of a list's or record's members after the first.
  let a = msg.args(sender)
  a.arity(1, msg, "(rest FRAME)")
  let items = a[0].members(msg)
  listOf(if items.len == 0: @[] else: items[1 .. ^1])

proc appendN(msg, self, sender: Val): Val {.native: "append".} =
  ## (append FRAME X …)
  ## FRAME with the values added: at the end of a list or record, as members
  ## of a set.
  let a = msg.args(sender)
  guard a.len > 0, "(append FRAME X …): " & $msg
  let frame = a[0]
  case frame.kind
  of bList, bRec:
    Val.buildFrame(frame.members(msg) & a[1 .. ^1], frame.kind, frame.mark)
  of bSet:
    var all: seq[Val]
    for each in frame.children:
      all.add each
    setOf(all & a[1 .. ^1])
  else:
    refuse "nothing to append to: " & $frame & " in " & $msg

proc concatN(msg, self, sender: Val): Val {.native: "concat".} =
  ## (concat X …)
  ## Lists joined into one list, or texts and symbols joined into one text.
  let a = msg.args(sender)
  if a.len == 0:
    return listOf(@[])
  if a[0].kind == bList:
    var all: seq[Val]
    for each in a:
      guard each.kind == bList, "concat takes all lists or all texts: " & $msg
      all.add each.members(msg)
    return listOf(all)
  var s = ""
  for each in a:
    guard each.kind in {bText, bSym}, "concat takes all lists or all texts: " & $msg
    s.add each.text
  textVal(s)

proc keysN(msg, self, sender: Val): Val {.native: "keys".} =
  ## (keys X)
  ## A list of a dict's keys or a set's members, in CE order.
  let a = msg.args(sender)
  a.arity(1, msg, "(keys X)")
  case a[0].kind
  of bDict: listOf(a[0].dict.keys)
  of bSet: listOf(a[0].els.data)
  else: refuse "no keys: " & $a[0] & " in " & $msg

proc valsN(msg, self, sender: Val): Val {.native: "vals".} =
  ## (vals DICT)
  ## A list of a dict's values, in the order of its keys.
  let a = msg.args(sender)
  a.arity(1, msg, "(vals DICT)")
  guard a[0].kind == bDict, "not a dict: " & $a[0] & " in " & $msg
  listOf(a[0].dict.vals)

proc hasN(msg, self, sender: Val): Val {.native: "has".} =
  ## (has X MEMBER)
  ## MEMBER when X holds it, and nil otherwise: a dict's key, a set's
  ## member, a list's or record's member, a text within a text.
  let a = msg.args(sender)
  a.arity(2, msg, "(has X MEMBER)")
  let (x, m) = (a[0], a[1])
  let found =
    case x.kind
    of bDict: m in x.dict
    of bSet: m in x.els
    of bList, bRec: m in x.members(msg)
    of bText, bSym:
      m.kind in {bText, bSym} and m.text in x.text
    else: false
  if found: holds(m) else: null

proc kindN(msg, self, sender: Val): Val {.native: "kind".} =
  ## (kind X)
  ## X's kind as a symbol: nil, number, text, symbol, bytes, list, record,
  ## dict or set, and object for an object.
  let a = msg.args(sender)
  a.arity(1, msg, "(kind X)")
  headSym(if a[0].isObject: "object" else: $a[0].kind)

proc textN(msg, self, sender: Val): Val {.native: "text".} =
  ## (text X)
  ## X as text: a text or symbol as it reads, anything else in text syntax.
  let a = msg.args(sender)
  a.arity(1, msg, "(text X)")
  textVal(a[0].textOf)

proc joinN(msg, self, sender: Val): Val {.native: "join".} =
  ## (join LIST SEP?)
  ## The members of LIST as text, with SEP between them.
  let a = msg.args(sender)
  guard a.len in 1 .. 2, "(join LIST SEP?): " & $msg
  var parts: seq[string]
  for each in a[0].members(msg):
    parts.add each.textOf
  textVal(parts.join(if a.len == 2: a[1].textOf else: ""))

proc printN(msg, self, sender: Val): Val {.native: "print".} =
  ## (print X …)
  ## Prints the values on one line, texts as they read, and answers nil.
  var parts: seq[string]
  for each in msg.args(sender):
    parts.add each.textOf
  try:
    stdout.writeLine parts.join(" ")
  except IOError as e:
    refuse "can't print: " & e.msg
  null

# ================
# Control
# ================

proc whileN(msg, self, sender: Val): Val {.native: "while".} =
  ## (while TEST FORM …)
  ## The forms in turn for as long as TEST isn't nil, answering the last
  ## value they gave, or nil.
  guard msg.len >= 2, "(while TEST FORM …): " & $msg
  let test = msg.getChild(1)
  result = null
  while test.eval(sender).kind != bNil:
    for i in 2 ..< msg.len:
      result = msg.getChild(i).eval(sender)

# ================
# Introspection
# ================

proc docOf*(v: Val): Val =
  ## what v's Doc layer holds, nil when it has none
  let d = v.layers[Doc]
  if not d.isNil:
    result = d.text

proc carried(v: Val): seq[string] =
  ## the heads of the layers v carries, its id and doc aside
  for each in v.layers:
    if each of Identity or each of Doc:
      continue
    let head = each.headOf
    if not head.isNil:
      result.add head.text

proc describe*(v: Val): Val =
  ## v's id, the layers it carries as written apart from its slots, its
  ## slot names, and what it delegates to
  let id = v.idOf
  var forms: seq[Val]
  for each in v.layers:
    if each of Identity or each of Slots:
      continue
    let form = each.mold
    if not form.isNil:
      forms.add form
  let
    idv = if id.isNil: null else: id
    layers = setOf(forms)
    slots = listOf(v.slotNames)
    parent = if v.parentOf.isNil: null else: v.parentOf
  bl"{id: $idv layers: $layers slots: $slots parent: $parent}"

proc describeN(msg, self, sender: Val): Val {.native: "describe".} =
  ## (describe X)
  ## A dict of X's id, the layers it carries as written apart from its
  ## slots, its slot names and its parent.
  let a = msg.args(sender)
  a.arity(1, msg, "(describe X)")
  a[0].describe

proc slotsN(msg, self, sender: Val): Val {.native: "slots".} =
  ## (slots OBJ)
  ## A list of the names of OBJ's own slots.
  let a = msg.args(sender)
  a.arity(1, msg, "(slots OBJ)")
  listOf(a[0].slotNames)

proc parentOfN(msg, self, sender: Val): Val {.native: "parent-of".} =
  ## (parent-of OBJ)
  ## What OBJ delegates to, nil for none. The root ends every chain.
  let a = msg.args(sender)
  a.arity(1, msg, "(parent-of OBJ)")
  result = a[0].parentOf
  if result.isNil: result = null

proc documentN(msg, self, sender: Val): Val {.native: "document".} =
  ## (document REF DOC)
  ## Puts the doc DOC, a text or a dict, on the object REF names. man shows
  ## it from then on.
  matchValue msg:
  of "($_ $r $doc)":
    let obj = r.deref(sender)
    guard obj.isObject, "only an object carries a doc: " & $r
    result = doc.eval(sender)
    guard result.kind in {bText, bDict}, "a doc is a text or a dict: " & $result
    obj.putLayer bl"(doc $result)"
  else: refuse "(document REF DOC): " & $msg

proc traceListener(event: Val) {.nimcall, raises: [].} =
  try:
    if event.kind == bRec and event.getChild(0) == headSym"sent":
      stdout.writeLine "  " & $event
  except CatchableError:
    discard

proc tracing(on: bool) =
  image.tracing = on
  var kept: seq[Listener]
  for each in image.listeners:
    if each != Listener(traceListener):
      kept.add each
  if on:
    kept.add Listener(traceListener)
  image.listeners = kept

proc traceN(msg, self, sender: Val): Val {.native: "trace".} =
  ## (trace on), (trace off), (trace FORM)
  ## Prints each message sent, as (sent MSG TO), while on, or while FORM is
  ## evaluated, answering its value.
  matchValue msg:
  of "($_ on)":
    tracing(true)
    result = sTrue
  of "($_ off)":
    tracing(false)
    result = null
  of "($_ $form)":
    let was = image.tracing
    tracing(true)
    try:
      result = form.eval(sender)
    finally:
      tracing(was)
  else: refuse "(trace on), (trace off) or (trace FORM): " & $msg

# ================
# The manual
# ================

proc unwrapped(text: string): string =
  ## text's lines joined into paragraphs, an empty line between two
  var paragraphs: seq[string]
  var current: seq[string]
  for line in text.strip.splitLines:
    if line.strip.len == 0:
      if current.len > 0:
        paragraphs.add current.join(" ")
        current = @[]
    else:
      current.add line.strip
  if current.len > 0:
    paragraphs.add current.join(" ")
  paragraphs.join("\n\n")

proc firstSentence(text: string): string =
  ## text up to the end of its first sentence
  let stop = text.find(". ")
  if stop < 0: text.splitLines[0] else: text[0 .. stop]

type DocParts = object
  usage, summary, body: string
  see: seq[string]

proc parts(doc: Val): DocParts =
  ## a doc's usage, summary, body and see-also, from either shape
  case doc.kind
  of bText:
    let lines = doc.text.strip.splitLines
    if lines.len > 0 and lines[0].startsWith("("):
      result.usage = lines[0]
      result.summary = lines[1 .. ^1].join("\n").unwrapped
    else:
      result.summary = doc.text.unwrapped
  of bDict:
    for (k, x) in doc.dict.pairs:
      if k.kind != bSym:
        continue
      case k.text
      of "usage": result.usage = x.textOf
      of "summary": result.summary = x.textOf
      of "body": result.body = x.textOf
      of "see":
        if x.kind == bList:
          for each in x.children:
            result.see.add each.textOf
      else: discard
  else:
    result.summary = doc.textOf

proc oneLine(doc: Val): string =
  ## a doc's usage and the first line of its summary
  let p = doc.parts
  let summary = if p.summary.len > 0: p.summary.firstSentence else: ""
  if p.usage.len > 0: p.usage & "  " & summary else: summary

proc indented(text: string): string =
  for line in text.splitLines:
    result.add "  " & line & "\n"

proc manual(): Val =
  let root = image.root
  if not root.isNil:
    result = root.ownSlot(headSym"manual")

proc topic(name: Val): Val =
  let m = manual()
  if not m.isNil and name.kind == bSym:
    result = m.ownSlot(name)

proc manOf*(name: string, v: Val): string =
  ## the manual's page for v, called name: its doc, the layers it carries
  ## past its slots and doc, and its slots past the system's `>>` ones
  result = name & "\n"
  if not v.isObject:
    return result & indented(name & " holds " & $v & ", a " & $v.kind)
  let doc = v.docOf
  if doc.isNil:
    result.add indented("no doc")
  else:
    let p = doc.parts
    if p.usage.len > 0: result.add indented(p.usage)
    if p.summary.len > 0: result.add indented(p.summary)
    if p.body.len > 0: result.add "\n" & indented(p.body)
    if p.see.len > 0: result.add indented("see also: " & p.see.join(" "))
  var heads: seq[string]
  for head in v.carried:
    if head != "slots":
      heads.add head
  if heads.len > 0:
    result.add indented("carries: " & heads.join(" "))
  var names: seq[string]
  for each in v.slotNames:
    if not each.textOf.startsWith(">>"):
      names.add each.textOf
  if names.len > 0:
    result.add indented("slots: " & names.join(" "))
  if doc.isNil:
    let id = v.idOf
    result.add indented("id: " & (if id.isNil: "none, not in the image" else: $id))
    let parent = v.parentOf
    if not parent.isNil:
      result.add indented("parent: " & $parent)

proc manFor*(name, sender: Val): string =
  ## the page for what name names from sender, then the manual's topic of
  ## that name, refusing when there is neither
  var found = false
  try:
    let v = name.deref(sender)
    result = manOf(name.textOf, v)
    found = true
  except BasslineError:
    discard
  let t = topic(name)
  if not t.isNil:
    if found: result.add "\n"
    result.add manOf("topic " & name.textOf, t)
    found = true
  guard found, "no manual entry for " & $name

proc manIndex*(): string =
  ## every documented name in the root with its usage and summary, then the
  ## manual's topics
  let root = image.root
  var lines: seq[(string, string)]
  for name in root.slotNames:
    let v = root.ownSlot(name)
    if v.isObject and not v.docOf.isNil:
      lines.add (name.textOf, v.docOf.oneLine)
  lines.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
  var width = 0
  for (name, _) in lines:
    width = max(width, name.len)
  result = "names in the root\n"
  for (name, line) in lines:
    result.add "  " & name.alignLeft(width) & "  " & line & "\n"
  let m = manual()
  if not m.isNil:
    var topics: seq[string]
    for each in m.slotNames:
      topics.add each.textOf
    result.add "topics in the manual: " & topics.join(" ") &
      "\n(man NAME) for a name or a topic, (apropos WORD) to search\n"

proc aproposText*(word: string): string =
  ## each name in the root and topic in the manual whose name or doc holds
  ## word, any case, with its usage and summary
  let w = word.toLowerAscii
  proc matches(name: string, doc: Val): bool =
    name.toLowerAscii.contains(w) or
      (not doc.isNil and ($doc).toLowerAscii.contains(w))
  var lines: seq[string]
  let root = image.root
  for name in root.slotNames:
    let v = root.ownSlot(name)
    let doc = if v.isObject: v.docOf else: nil
    if matches(name.textOf, doc):
      lines.add "  " & name.textOf & (if doc.isNil: "" else: "  " & doc.oneLine)
  let m = manual()
  if not m.isNil:
    for name in m.slotNames:
      let doc = m.ownSlot(name).docOf
      if matches(name.textOf, doc):
        lines.add "  topic " & name.textOf & (if doc.isNil: "" else: "  " & doc.oneLine)
  lines.join("\n")

proc manN(msg, self, sender: Val): Val {.native: "man".} =
  ## (man NAME?)
  ## Prints the page for what NAME names, and the manual's topic of that
  ## name, or with no NAME every documented name and the topics.
  let text =
    case msg.len
    of 1: manIndex()
    of 2: manFor(msg.getChild(1), sender)
    else: refuse "(man NAME?): " & $msg
  try:
    stdout.write text
  except IOError as e:
    refuse "can't print: " & e.msg
  null

proc aproposN(msg, self, sender: Val): Val {.native: "apropos".} =
  ## (apropos WORD)
  ## Prints each name and topic whose name or doc holds WORD, a symbol or
  ## text, in any case.
  guard msg.len == 2 and msg.getChild(1).kind in {bSym, bText},
    "(apropos WORD): " & $msg
  try:
    stdout.writeLine aproposText(msg.getChild(1).text)
  except IOError as e:
    refuse "can't print: " & e.msg
  null

{.pop.}

# ================
# Booting
# ================

const bootText = staticRead("boot.bl")

proc bootLibrary*(): Val {.raises: [BasslineError].} =
  ## a new image: boot, then every form in boot.bl evaluated in the root.
  ## Answers the root
  result = boot()
  discard result.run(bootText)
