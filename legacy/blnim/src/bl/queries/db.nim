import std/sugar
import ../core
import ./stream

type
  TableError = object of BasslineError
  Table = ref object
    pk: Value
    columns: BSet
    values: BDict
  Query = object
    t: Table
    s: Stream[Value]

refuseWith TableError

proc newTable(pk, columns: Value): Table =
  columns.expectKind({bSet}, unmarked)
  var cols = columns.els.copy
  cols.incl pk
  Table(pk: pk, columns: columns.els.copy, values: newBDict())

proc insertOne(t: Table, v: Value) =
  v.expectKind(bDict, unmarked)
  var 
    row = initDict()
    pk: Value
  for k in t.columns:
    if t.pk == k:
      guard k in v.dict, "missing primary key: " & $t.pk
      pk = row[k]
    if k in v.dict:
      row[k] = v[k]
    else:
      row[k] = null()
  t.values[pk] = row

proc insert(t: Table, v: Value) =
  v.expectKind({bSet, bDict}, unmarked)
  case v.kind
  of bDict: t.insertOne(v)
  of bSet:
    for each in v.els:
      t.insertOne(each)
  else: discard

# ================
# Queries
# ================

proc query(t: Table): Query =
  let s = streamOf:
    yieldEach t.values
  Query(t: t, s: s)

proc select(q: Query, c: Value, p: (Value) -> bool): Query =
  guard c in q.t.columns, "no column in table: " & $c
  let s = q.s.filter (it) => p(it[c])
  Query(t: q.t, s: s)

iterator items*(q: Query): Value =
  yieldEach q.s

# ================
# Predicates
# ================

proc isNumeric(a: Value): auto =
  a.isKind({bNum}, unmarked)

template numeric(a, b, op: untyped): untyped =
  (if a.isNumeric and b.isNumeric:
      op(a.num, b.num)
    else:
      op(a, b))

func eq(a: Value): auto =
  (b: Value) => numeric(a, b, `==`)

func gt(a: Value): auto =
  (b: Value) => numeric(a, b, `<`)

func lt(a: Value): auto =
  (b: Value) => numeric(a, b, `>`)

when isMainModule:
  let
    name = rv"name"
    age = rv"age"
    email = rv"email"
    phoneNumber = rv"phone-number"

  let table = newTable(sym"name", initSet([name, age, email, phoneNumber]))
  
  let users = rv"""{
    {name: alexander age: 25}
    {name: ariel phone-number: 123 age: 26}
    {name: foo age: 420 email: foo@bar.com}
  }"""

  table.insert(users)

  for user in table.query
      .select(age, gt(20'bn))
      .select(age, lt(30'bn)):
    echo user