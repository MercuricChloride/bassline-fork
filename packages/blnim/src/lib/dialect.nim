include pkg/prelude
## dialect: declare a bassline dialect shape as an ordinary Nim type;
## toValue / fromValue are derived from the type's structure.
##
##   type
##     Digest {.blRecord: "digest".} = object
##       algo*: Sym
##       hash*: seq[byte]
##
##   toValue(Digest(algo: Sym"sha256", hash: h))   -> (digest sha256 0x..)
##   fromValue(v, Digest)                          -> Option[Digest]
##
## Field types map to value kinds:
##   Value          -> passthrough
##   Sym            -> symbol
##   string         -> text
##   DecimalString  -> integer (lossless)
##   SomeSignedInt  -> integer (parse fails if it doesn't fit)
##   enum           -> symbol of the enum name (polarity vocabulary)
##   seq[byte]      -> bytes
##   array[N, byte] -> bytes of exactly N
##   Lit[S]         -> the symbol S, pinned (a constant slot)
##   Option[T]      -> T, or explicit nil (record slot) / absent key (dict)
##   seq[T]         -> list of T   ({.blSet.} on the field -> set of T)
##   object         -> nested dialect ({.blRecord: h.} or {.blDict.})
##
## Recognition is strict: exact head, exact arity, no unknown dict keys,
## and marked values are refused everywhere except Value passthrough.
## fromValue never raises on foreign data; it answers none.

import std/[strutils, macros]
import pkg/core/values

type
  Sym* = distinct string ## a field that is a bassline symbol (string fields are text)

  Lit*[S: static string] = object ## a slot pinned to the symbol S; carries no data.

func `==`*(a, b: Sym): bool {.borrow.}
func `$`*(s: Sym): string {.borrow.}
func `==`*(a: Sym, b: string): bool =
  string(a) == b
func `==`*(a: string, b: Sym): bool =
  a == string(b)

template blRecord*(head: string) {.pragma.}
  ## type pragma: this object is a record dialect with the given head

template blDict*() {.pragma.}
  ## type pragma: this object is a dict dialect; keys are the field
  ## names as symbols, Option fields may be silent (absent key)

template blSet*() {.pragma.}
  ## field pragma: this seq renders as set framing instead of a list

template blKey*(key: string) {.pragma.}
  ## field pragma (dict dialects): wire key overriding the field name

func litOf[S: static string](t: typedesc[Lit[S]]): string =
  S

# ================ TO VALUE ================

func toValue*[T](x: sink T): Value

func toValueObj[T: object](x: sink T): Value =
  mixin toValue
  var y = x
  when T.hasCustomPragma(blRecord):
    var fields = @[sym(T.getCustomPragmaVal(blRecord))]
    for name, f in y.fieldPairs:
      when hasCustomPragma(f, blSet):
        when typeof(f) is seq[Value]:
          fields.add values.set(move(f))
        elif typeof(f) is seq:
          var els = newSeqOfCap[Value](f.len)
          for it in f:
            els.add toValue(it)
          fields.add values.set(els)
        else:
          {.error: "blSet needs a seq field".}
      else:
        fields.add toValue(move(f))
    record(fields)
  elif T.hasCustomPragma(blDict):
    var entries: seq[(Value, Value)]
    for name, f in y.fieldPairs:
      const key =
        when hasCustomPragma(f, blKey):
          getCustomPragmaVal(f, blKey)
        else:
          name
      when typeof(f) is Option:
        if f.isSome:
          entries.add (sym(key), toValue(move(f.get)))
      else:
        entries.add (sym(key), toValue(move(f)))
    dict(entries)
  else:
    {.error: $T & " needs {.blRecord: \"head\".} or {.blDict.} to be a dialect".}

func toValue*[T](x: sink T): Value =
  mixin toValue
  when T is Value:
    x
  elif T is Sym:
    sym(string(x))
  elif T is Lit:
    sym(litOf(T))
  elif T is string:
    text(x)
  elif T is DecimalString:
    num(x)
  elif T is SomeSignedInt:
    num($x)
  elif T is enum:
    sym($x)
  elif T is seq[byte]:
    bytes(x)
  elif T is array:
    when typeof(default(T)[low(default(T))]) is byte:
      bytes(@x)
    else:
      {.error: "only byte arrays have a dialect mapping".}
  elif T is Option:
    if x.isSome:
      toValue(x.get)
    else:
      nilValue()
  elif T is seq:
    var els = newSeqOfCap[Value](x.len)
    for it in x:
      els.add toValue(it)
    list(els)
  elif T is object:
    toValueObj(x)
  else:
    {.error: "no dialect mapping for a field of type " & $T.}

# ================ FROM VALUE ================
# All entry points bind their target type through generic pattern
# matching ([T](t: typedesc[T]), [X](t: typedesc[Option[X]])) rather
# than typeof(...) extraction: pattern binding launders the type into
# a clean semantic symbol, which hasCustomPragma needs downstream.

func fromValue*[T](v: Value, t: typedesc[T]): Option[T]

func fromValue*[X](v: Value, t: typedesc[Option[X]]): Option[Option[X]] =
  ## outer Option: did the slot parse; inner: was it nil
  mixin fromValue
  if v.kind == bNil and not v.marked:
    some(none(X))
  else:
    let inner = fromValue(v, X)
    if inner.isSome:
      some(inner)
    else:
      none(Option[X])

func fromValue*[X](v: Value, t: typedesc[seq[X]]): Option[seq[X]] =
  mixin fromValue
  when X is byte:
    if v.kind == bBytes and not v.marked:
      some(v.bytes)
    else:
      none(seq[byte])
  else:
    if v.kind != bList or v.marked:
      return none(seq[X])
    var res: seq[X]
    for item in v.children:
      let p = fromValue(item, X)
      if p.isNone:
        return none(seq[X])
      res.add p.get
    some(res)

func match*[X](t: typedesc[X], v: Value): Option[X] =
  fromValue(v, t)

func fromValueObj[T](v: Value, t: typedesc[T]): Option[T] =
  mixin fromValue
  when T.hasCustomPragma(blRecord):
    if v.kind != bRecord or v.marked:
      return none(T)
    if v.contents[0] != sym(T.getCustomPragmaVal(blRecord)):
      return none(T)
    var res: T
    var i = 1
    for name, f in res.fieldPairs:
      if i >= v.contents.len:
        return none(T)
      when hasCustomPragma(f, blSet):
        let el = v.contents[i]
        if el.kind != bSet or el.marked:
          return none(T)
        for j in 0 ..< el.contents.len:
          let p = fromValue(el.contents[j], typeof(f[0]))
          if p.isNone:
            return none(T)
          f.add p.get
      else:
        let p = fromValue(v.contents[i], typeof(f))
        if p.isNone:
          return none(T)
        f = p.get
      inc i
    if i != v.contents.len:
      return none(T)
    some(res)
  elif T.hasCustomPragma(blDict):
    if v.kind != bDict or v.marked:
      return none(T)
    var res: T
    var matched = 0
    for name, f in res.fieldPairs:
      const key =
        when hasCustomPragma(f, blKey):
          getCustomPragmaVal(f, blKey)
        else:
          name
      let keyVal = sym(key)
      if v.hasKey(keyVal):
        let p = fromValue(v.at(keyVal), typeof(f))
        if p.isNone:
          return none(T)
        f = p.get
        inc matched
      else:
        when typeof(f) isnot Option:
          return none(T)
    if matched != pairsLen(v):
      # unknown keys: this shape is closed
      return none(T)
    some(res)
  else:
    {.error: $T & " needs {.blRecord: \"head\".} or {.blDict.} to be a dialect".}

func fromValue*[T](v: Value, t: typedesc[T]): Option[T] =
  mixin fromValue
  when T is Value:
    some(v)
  elif T is Sym:
    if v.kind == bSym and not v.marked:
      some(Sym(string(v.text)))
    else:
      none(T)
  elif T is Lit:
    if v == sym(litOf(T)):
      some(default(T))
    else:
      none(T)
  elif T is string:
    if v.kind == bText and not v.marked:
      some(string(v.text))
    else:
      none(T)
  elif T is DecimalString:
    if v.kind == bNum and not v.marked:
      some(v.num)
    else:
      none(T)
  elif T is SomeSignedInt:
    if v.kind != bNum or v.marked:
      return none(T)
    var n: BiggestInt
    try:
      n = parseBiggestInt(string(v.num))
    except ValueError:
      return none(T)
    if n >= BiggestInt(low(T)) and n <= BiggestInt(high(T)):
      some(T(n))
    else:
      none(T)
  elif T is enum:
    if v.kind != bSym or v.marked:
      return none(T)
    try:
      some(parseEnum[T](string(v.text)))
    except ValueError:
      none(T)
  elif T is array:
    when typeof(default(T)[low(default(T))]) is byte:
      const n = default(T).len
      if v.kind == bBytes and not v.marked and v.bytes.len == n:
        var res: T
        for i in 0 ..< n:
          res[i] = v.bytes[i]
        some(res)
      else:
        none(T)
    else:
      {.error: "only byte arrays have a dialect mapping".}
  elif T is object:
    fromValueObj(v, T)
  else:
    {.error: "no dialect mapping for a field of type " & $T.}