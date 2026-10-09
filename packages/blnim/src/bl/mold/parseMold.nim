## A description read into a tree: the structs it declares, each a list
## of named fields, and what each field is held as. The macro walks the
## tree to generate types; anything else may walk it too, as the tree is
## plain data, read the same at compile time and at runtime.
##
##   DESCRIPTION := STRUCT | {STRUCT …}
##   STRUCT      := (struct NAME PRAGMAS? (FIELD PRAGMAS? TYPE) …)
##   TYPE        := KIND | value | any | NAME
##                | (KIND PRAGMAS? ARG …) | [T] | {T} | {K: V}
##   PRAGMAS     := {FLAG … (KEY VALUE …) …}
##
## `!(struct …)` molds marked values; `symbol!` or `!(list T)` is a
## marked part. A struct's fields are written either as a dict,
## `(NAME {FIELD: VALUE …})`, or as a record in field order,
## `(NAME VALUE …)`, and read back by name either way.

import std/[tables, strutils, options, algorithm, sugar]
import ../core
import ./mold

refuseWith MoldError

type
  TypeKind* = enum
    tkKind   ## a value of one kind, held as that kind's own Nim type
    tkAny    ## a value of any kind, held as a Value
    tkStruct ## a struct, by name
    tkList   ## a list, every member of one TYPE
    tkSet    ## a set, every member of one TYPE
    tkRecord ## a record, every member of one TYPE, its head too
    tkDict   ## a dict, every key of one TYPE and every value of one

  Type* = ref object
    ## what a part of a value is held as
    marked*: bool ## the part is marked; for `any`, nothing is said
    case kind*: TypeKind
    of tkKind:
      valueKind*: Kind
      len*: Option[int]   ## (len N): exactly N bytes
      oneOf*: seq[string] ## (one-of S …): one of these symbols
    of tkAny:
      markFree*: bool ## `any`, marked or not; `value` is marked as said
    of tkStruct:
      name*: string
    of tkList, tkSet, tkRecord:
      each*: Type
    of tkDict:
      key*, val*: Type

  Field* = object
    name*, nimName*: string
    optional*: bool ## left out when there is nothing to say
    typ*: Type

  Struct* = ref object
    name*, nimName*: string
    marked*: bool ## its values are marked
    exact*: bool  ## a field more than described is refused, not left behind
    rep*: Rep     ## how `mold` writes it and `load` reads it
    fields*: seq[Field]
    byName*: seq[int] ## its fields' places, in the order a dict holds them
    shape*: Shape     ## what it says of its values as a whole

  Context* = object
    ## the structs a description declares, by name, in order
    structs*: OrderedTable[string, Struct]

const
  Kinds = ["number", "text", "symbol", "bytes", "list", "record", "dict", "set"]
  Reserved = @Kinds & @["nil", "value", "any", "struct"]

# ================ names ================

proc nimSpelling*(name: string, capital: bool): string =
  ## `file-entry` as a Nim identifier: FileEntry for a type, fileEntry
  ## for a field
  var upper = capital
  for c in name:
    if c == '-':
      upper = true
    elif upper:
      result.add c.toUpperAscii
      upper = false
    else:
      result.add c
  guard validIdentifier(result), name & " has no spelling as a Nim name"

proc nameOf(v: Value, what: string): string =
  guard v.isKind(bSym) and not v.mark,
    "a " & what & " is named by an unmarked symbol: " & $v
  v.text

# ================ pragmas ================

type Pragmas = object
  flags: seq[string]
  keyed: OrderedTable[string, seq[Value]]

proc isPragmas(v: Value): bool =
  v.isKind(bSet) and not v.mark

proc readPragmas(v: Value, where: string, flags, keys: openArray[string]): Pragmas =
  ## `{FLAG … (KEY VALUE …) …}`, each FLAG and KEY one `where` takes
  for p in v.els:
    if p.isKind(bSym) and not p.mark:
      guard p.text in flags, where & " takes no pragma " & p.text
      result.flags.add p.text
    else:
      guard p.isKind(bRec) and not p.mark and p.len >= 2 and
        p[0].isKind(bSym) and not p[0].mark,
        where & ": a pragma is a FLAG or (KEY VALUE …): " & $p
      guard p[0].text in keys, where & " takes no pragma (" & p[0].text & " …)"
      result.keyed[p[0].text] = p.items.data[1 .. ^1]

proc one(p: Pragmas, key, where: string): Option[Value] =
  if key in p.keyed:
    guard p.keyed[key].len == 1, where & ": (" & key & " …) takes one value"
    return some p.keyed[key][0]

proc nimPragma(p: Pragmas, where: string): Option[string] =
  let n = p.one("nim", where)
  if n.isSome:
    guard n.get.isKind(bSym) and not n.get.mark and validIdentifier(n.get.text),
      where & ": (nim NAME) takes a Nim identifier"
    return some n.get.text

# ================ TYPEs ================

proc parseType*(t: Value, where: string): Type

proc args(t: Value, arity: int, where: string): (Pragmas, seq[Value]) =
  ## a `(KIND PRAGMAS? ARG …)` form's pragmas and its `arity` arguments
  let rest = t.items.data[1 .. ^1]
  if rest.len == arity + 1 and rest[0].isPragmas:
    let keys =
      if t[0].text == "bytes": @["len"]
      elif t[0].text == "symbol": @["one-of"]
      else: @[]
    (readPragmas(rest[0], where, [], keys), rest[1 .. ^1])
  else:
    guard rest.len == arity,
      where & ": (" & t[0].text & " …) takes " & $arity & " TYPEs: " & $t
    (Pragmas(), rest)

proc parseType*(t: Value, where: string): Type =
  ## what a part described by TYPE t is held as; refuses a TYPE nothing
  ## can be held as
  case t.kind
  of bSym, bText:
    case t.text
    of "nil", "struct":
      refuse where & ": " & t.text & " is not a TYPE"
    of "any":
      guard not t.mark, where & ": any is marked or not, so needs no mark"
      return Type(kind: tkAny, markFree: true)
    of "value":
      return Type(kind: tkAny, marked: t.mark)
    let kind = parseKind(t.text)
    if kind.isSome:
      return Type(kind: tkKind, valueKind: kind.get, marked: t.mark)
    guard not t.mark, where & ": a struct is marked as its own description says"
    return Type(kind: tkStruct, name: t.text)
  of bList:
    guard t.len == 1, where & ": [T] has one TYPE: " & $t
    return Type(kind: tkList, marked: t.mark,
                each: parseType(t[0], where & " member"))
  of bSet:
    guard t.len == 1, where & ": {T} has one TYPE: " & $t
    var each: Value
    for m in t.els: each = m
    return Type(kind: tkSet, marked: t.mark,
                each: parseType(each, where & " member"))
  of bDict:
    guard t.len == 1, where & ": {K: V} has one KEY: VALUE: " & $t
    var k, v: Value
    for key, val in t.dict: (k, v) = (key, val)
    return Type(kind: tkDict, marked: t.mark, key: parseType(k, where & " key"),
                val: parseType(v, where & " value"))
  of bRec:
    guard t[0].isKind(bSym) and not t[0].mark,
      where & ": a TYPE form is (KIND PRAGMAS? ARG …): " & $t
    case t[0].text
    of "list", "set", "record":
      let (_, a) = t.args(1, where)
      let each = parseType(a[0], where & " member")
      return case t[0].text
        of "list": Type(kind: tkList, marked: t.mark, each: each)
        of "set": Type(kind: tkSet, marked: t.mark, each: each)
        else: Type(kind: tkRecord, marked: t.mark, each: each)
    of "dict":
      let (_, a) = t.args(2, where)
      return Type(kind: tkDict, marked: t.mark,
                  key: parseType(a[0], where & " key"),
                  val: parseType(a[1], where & " value"))
    of "number", "text", "symbol", "bytes":
      let (p, _) = t.args(0, where)
      result = Type(kind: tkKind, valueKind: parseKind(t[0].text).get,
                    marked: t.mark)
      let n = p.one("len", where)
      if n.isSome:
        guard n.get.isKind(bNum) and not n.get.mark and n.get.num.isInt and
          n.get.num.toInt >= 0, where & ": (len N) takes a count of bytes"
        result.len = some n.get.num.toInt
      if "one-of" in p.keyed:
        for s in p.keyed["one-of"]:
          guard s.isKind(bSym) and not s.mark,
            where & ": (one-of …) lists unmarked symbols"
          result.oneOf.add s.text
    else:
      refuse where & ": no TYPE form (" & t[0].text & " …)"
  else:
    refuse where & ": a TYPE is a kind, value, any or a struct by name, or " &
      "a TYPE form: " & $t

# ================ structs ================

proc toValue*(s: Struct): Value

proc parseField(f: Value, struct: string): Field =
  ## `(NAME PRAGMAS? TYPE)`
  guard f.isKind(bRec) and not f.mark and f.len in 2..3,
    struct & ": a field is (NAME PRAGMAS? TYPE): " & $f
  result.name = nameOf(f[0], "field")
  let where = struct & " " & result.name
  var p: Pragmas
  if f.len == 3:
    guard f[1].isPragmas, where & ": a field's pragmas are a set: " & $f[1]
    p = readPragmas(f[1], where, ["optional"], ["nim"])
  result.optional = "optional" in p.flags
  result.nimName = p.nimPragma(where).get(nimSpelling(result.name, false))
  result.typ = parseType(f[f.len - 1], where)

proc parseStruct*(s: Value): Struct =
  ## `(struct NAME PRAGMAS? (FIELD PRAGMAS? TYPE) …)`
  guard s.isKind(bRec) and s.len >= 2 and s[0].isKind(bSym) and
    not s[0].mark and s[0].text == "struct",
    "a description is (struct NAME PRAGMAS? (FIELD TYPE) …): " & $s
  let name = nameOf(s[1], "struct")
  guard name notin Reserved, name & " is a TYPE already, not a struct's name"
  var
    p: Pragmas
    at = 2
  if s.len > 2 and s[2].isPragmas:
    p = readPragmas(s[2], name, ["exact"], ["rep", "nim"])
    at = 3
  result = Struct(name: name, marked: s.mark, exact: "exact" in p.flags,
                  nimName: p.nimPragma(name).get(nimSpelling(name, true)))
  let rep = p.one("rep", name)
  if rep.isSome:
    guard rep.get.isKind(bSym) and not rep.get.mark and
      rep.get.text in ["dict", "record"], name & ": (rep dict) or (rep record)"
    result.rep = if rep.get.text == "dict": repDict else: repRecord
  for i in at ..< s.len:
    let f = parseField(s[i], name)
    for seen in result.fields:
      guard seen.name != f.name, name & ": " & f.name & " is described twice"
      guard seen.nimName != f.nimName,
        name & ": " & f.name & " and " & seen.name & " are one Nim name"
    result.fields.add f
  result.shape = Shape(head: sym(name), marked: result.marked,
                       exact: result.exact, rep: result.rep,
                       description: $result.toValue)
  for i, f in result.fields:
    result.shape.names.add sym(f.name)
    result.shape.optional.add f.optional
    result.byName.add i
  let names = result.shape.names
  result.byName.sort((a, b) => cmp(names[a], names[b]))

proc parseMold*(desc: Value): Context =
  ## one struct, or a set of them declared together
  if desc.isKind(bSet):
    guard not desc.mark, "mark each struct in the set, not the set"
    for each in desc.els:
      let s = parseStruct(each)
      guard s.name notin result.structs, s.name & " is described twice"
      result.structs[s.name] = s
  else:
    let s = parseStruct(desc)
    result.structs[s.name] = s
  var nims: seq[string]
  for s in result.structs.values:
    guard s.nimName notin nims, s.nimName & " names two structs"
    nims.add s.nimName

# ================ the tree, as a value ================

proc toValue*(t: Type): Value =
  ## the TYPE, written in its long form
  result = case t.kind
    of tkKind:
      var p = initSet()
      if t.len.isSome: p.incl initRec(@[sym"len", num(t.len.get)])
      if t.oneOf.len > 0:
        var r = @[sym"one-of"]
        for o in t.oneOf: r.add sym(o)
        p.incl initRec(r)
      if p.len == 0: sym($t.valueKind)
      else: initRec(@[sym($t.valueKind), p])
    of tkAny: sym(if t.markFree: "any" else: "value")
    of tkStruct: sym(t.name)
    of tkList: initRec(@[sym"list", t.each.toValue])
    of tkSet: initRec(@[sym"set", t.each.toValue])
    of tkRecord: initRec(@[sym"record", t.each.toValue])
    of tkDict: initRec(@[sym"dict", t.key.toValue, t.val.toValue])
  result.mark = t.marked

proc toValue*(s: Struct): Value =
  ## the struct, written in its long form with every pragma said
  var p = @[initRec(@[sym"nim", sym(s.nimName)]),
            initRec(@[sym"rep", sym($s.rep)])]
  if s.exact: p.add sym"exact"
  var items = @[sym"struct", sym(s.name), initSet(p)]
  for f in s.fields:
    var fp: seq[Value]
    if f.optional: fp.add sym"optional"
    if f.nimName != f.name: fp.add initRec(@[sym"nim", sym(f.nimName)])
    items.add(if fp.len > 0: initRec(@[sym(f.name), initSet(fp), f.typ.toValue])
              else: initRec(@[sym(f.name), f.typ.toValue]))
  initRec(items, s.marked)
