import std/[macros, sequtils, strutils]
import petit_parser
import ./[micro, text]

refuseWith BasslineError

type Macro = ref object of Live
  nn*: NimNode

proc codegen(self: Node): NimNode

proc codegen(n: Value): NimNode =
  let m = newLit(n.mark)
  template asSeq(exp): untyped =
    newCall("@", newTree(nnkBracket, exp))
  case n.kind
  of bNil:
    newCall(bindSym"toNode", newCall(bindSym"null", m))
  of bNum:
    newCall(bindSym"Num", newLit($n.vnum), m)
  of bText:
    newCall(bindSym"Text", newLit(n.vstr), m)
  of bSym:
    newCall(bindSym"Sym", newLit(n.vstr), m)
  of bBytes:
    newCall(bindSym"Bytes", newLit(n.vstr), m)
  of bList:
    var els = asSeq n.vseq.mapit(codegen(it))
    newCall(bindSym"List", els, m)
  of bRec:
    var els = asSeq n.vseq.mapit(codegen(it))
    newCall(bindSym"Rec", els, m)
  of bDict:
    var entries = asSeq n.vdict.entries.mapIt(
      nnkTupleConstr.newTree(it.key.codegen, it.val.codegen))
    newCall(bindSym"Dict", entries, m)
  of bSet:
    var
      entries = asSeq n.vset.data.mapIt(it.codegen)
    newCall(bindSym"Set", entries, m)

proc codegen(self: Node): NimNode =
  case self
  of Plain(n):
    n.codegen
  of Bound(l):
    if l of Macro:
      Macro(l).nn
    else:
      refuse "cannot use reify at compile time"

proc placed(n, at: NimNode): NimNode =
  # allows a node made in a macro is reported at the line of the macro that made it
  n.copyLineInfo(at)
  for each in n:
    discard each.placed(at)
  n

proc expandValue(src: NimNode): NimNode =
  try:
    var r = basslineParser().parse(src.strVal)
    if not r.isSuccess:
      error(r.message, src)
    var root = r.take
    proc p(n: var Value): bool =
      case n.kind
      of bSym: n.vstr.startsWith("$") and n.vstr.len > 1
      else: false
    proc f(n: var Node) =
      var id = n.asValue.vstr
      id.removePrefix("$")
      if id.startsWith('$'):
        # double $ just drops one
        n.asValue.vstr = id
      else:
        let 
          iden = ident(id)
          nn = if n.asValue.mark: newCall("!", iden) else: iden
        n = toNode Macro(nn: nn)
    root.rewrite(p, f)
    result = codegen(root).placed(src)
  except BasslineError as e:
    error(e.msg, src)

macro bl*(src: string): untyped =
  result = expandValue(src)