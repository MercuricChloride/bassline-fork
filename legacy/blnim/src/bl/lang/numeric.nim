## Numbers over whole frames. A vector is a list of integers and a matrix
## a list of vectors, so they are values like any other, written, sent
## and signed as they are. Doing arithmetic on them is the host's work:
## each call takes whole frames and answers once, and the loop over their
## members runs in the host, not one call per member.
##
##   !(dot A B)  !(vsum A)            numbers
##   !(vadd A B) !(vsub A B) !(vmul A B) !(scale K A)
##                                     vectors, member by member
##   !(matmul A B)                     a matrix
##
## A frame's members are read as host integers once, and kept against the
## frame (`VectorOf`, `MatrixOf`), shared rather than copied, so a vector
## handed to many calls is read once.
## A member that isn't an integer the host holds is refused, and so is a
## sum or product past what it holds.

import ./[base, reps]
export base, reps

refuseWith BasslineError

type
  Ints* = ref seq[int]       ## a vector's members, as host integers
  Rows* = ref seq[seq[int]]  ## a matrix's rows, as host integers

proc ints(v: Value): Ints =
  guard v.isKind(bList, unmarked), "a vector is an unmarked list: " & $v
  result = new Ints
  result[] = newSeqOfCap[int](v.items.len)
  for m in v.items.data:
    guard m.isKind(bNum, unmarked) and m.num.isInt,
      "a vector holds integers the host holds: " & $m
    result[].add m.num.toInt

let VectorOf* = reading[Ints](sym"ints", ints)
  ## a vector's members, read once and shared

proc rows(v: Value): Rows =
  guard v.isKind(bList, unmarked), "a matrix is an unmarked list: " & $v
  result = new Rows
  for row in v.items.data: result[].add VectorOf[row][]
  for row in result[]:
    guard row.len == result[0].len, "a matrix's rows are one width"

let MatrixOf* = reading[Rows](sym"rows", rows)
  ## a matrix's rows, read once and shared

moldable """{
  !(struct dot {exact (rep record)} (a any) (b any))
  !(struct vsum {exact (rep record)} (a any))
  !(struct vadd {exact (rep record)} (a any) (b any))
  !(struct vsub {exact (rep record)} (a any) (b any))
  !(struct vmul {exact (rep record)} (a any) (b any))
  !(struct scale {exact (rep record)} (k number) (a any))
  !(struct matmul {exact (rep record)} (a any) (b any))
}"""

proc vector(xs: openArray[int]): Value =
  var items = newSeqOfCap[Value](xs.len)
  for x in xs: items.add num(x)
  initList(items)

proc pair(a, b: Value, what: string): (Ints, Ints) =
  result = (VectorOf[a], VectorOf[b])
  guard result[0][].len == result[1][].len, what & " of vectors of two lengths"

method run(c: Dot, cx: Cx): Stream[Value] =
  let (a, b) = pair(c.a, c.b, "dot")
  var total = 0
  for i in 0 ..< a[].len: total = added(total, multiplied(a[][i], b[][i]))
  just num(total)

method run(c: Vsum, cx: Cx): Stream[Value] =
  var total = 0
  for x in VectorOf[c.a][]: total = added(total, x)
  just num(total)

template memberwise(T, what, op) =
  method run(c: T, cx: Cx): Stream[Value] =
    let (a, b) = pair(c.a, c.b, what)
    var r = newSeq[int](a[].len)
    for i in 0 ..< a[].len: r[i] = op(a[][i], b[][i])
    just vector(r)

memberwise Vadd, "vadd", added
memberwise Vsub, "vsub", subtracted
memberwise Vmul, "vmul", multiplied

method run(c: Scale, cx: Cx): Stream[Value] =
  guard c.k.isInt, "scale: past what this host's integers hold"
  let k = c.k.toInt
  var r: seq[int]
  for x in VectorOf[c.a][]: r.add multiplied(k, x)
  just vector(r)

method run(c: Matmul, cx: Cx): Stream[Value] =
  let (a, b) = (MatrixOf[c.a], MatrixOf[c.b])
  guard a[].len > 0 and b[].len > 0 and a[][0].len == b[].len,
    "matmul of matrices that don't meet"
  var rows: seq[Value]
  for i in 0 ..< a[].len:
    var row = newSeq[int](b[][0].len)
    for j in 0 ..< b[][0].len:
      for k in 0 ..< b[].len:
        row[j] = added(row[j], multiplied(a[][i][k], b[][k][j]))
    rows.add vector(row)
  just initList(rows)

proc numeric*(cx: Cx) =
  ## the vocabulary, installed in cx
  cx.install(native Dot, native Vsum, native Vadd, native Vsub, native Vmul,
             native Scale, native Matmul)
