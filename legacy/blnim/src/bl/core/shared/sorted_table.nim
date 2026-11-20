import std/algorithm
import ./shared

type
  SortedTable*[K, V] = object
    keys: seq[K]
    vals: seq[V]

func keys*[K,V](self: SortedTable[K,V]): lent seq[K] =
  self.keys

func vals*[K,V](self: SortedTable[K,V]): lent seq[V] =
  self.vals

func toSortedTable*[K,V](keys: sink seq[K], vals: sink seq[V], sorted = false): SortedTable[K, V] =
  mixin cmp
  doAssert keys.len == vals.len, "a value for every key"
  if sorted:
    return SortedTable[K,V](keys: keys, vals: vals)
  var
    ks = keys
    vs = vals
    order = newSeq[int](ks.len)
  for i in 0 ..< order.len:
    order[i] = i
  order.sort(proc (a, b: int): int = cmp(ks[a], ks[b]))
  result.keys = newSeqOfCap[K](ks.len)
  result.vals = newSeqOfCap[V](vs.len)
  for i in order:
    result.keys.add move(ks[i])
    result.vals.add move(vs[i])

func toSortedTable*[K,V](self: openArray[Entry[K,V]], sorted = false): SortedTable[K, V] =
  var
    keys = newSeqOfCap[K](self.len)
    vals = newSeqOfCap[V](self.len)
  for e in self:
    keys.add e.key
    vals.add e.val
  toSortedTable(move keys, move vals, sorted)

func lowerIdx[K,V](self: SortedTable[K,V], key: K): int =
  ## the first index whose key is not below key
  mixin cmp
  self.keys.lowerBound(key, cmp)

func indexOf*[K,V](self: SortedTable[K, V], key: K): int =
  ## key's index, or -1 when it has none
  mixin cmp
  let i = self.lowerIdx(key)
  if i < self.keys.len and cmp(self.keys[i], key) == 0: i else: -1

func put*[K,V](self: var SortedTable[K, V], key: sink K, val: sink V) =
  mixin cmp
  let i = self.lowerIdx(key)
  if i < self.keys.len and cmp(self.keys[i], key) == 0:
    self.vals[i] = val
  else:
    self.keys.insert(key, i)
    self.vals.insert(val, i)

func delete*[K,V](self: var SortedTable[K,V], key: K) =
  let i = self.indexOf(key)
  if i != -1:
    self.keys.delete(i)
    self.vals.delete(i)

func get*[K,V](self: SortedTable[K,V], key: K): lent V =
  let i = self.indexOf(key)
  if i == -1:
    raise newException(KeyError, "key not found")
  self.vals[i]

func len*[K,V](self: SortedTable[K,V]): Natural =
  self.keys.len

func low*[K,V](self: SortedTable[K,V]): lent K =
  self.keys[0]

func high*[K,V](self: SortedTable[K,V]): lent K =
  self.keys[self.keys.len - 1]

# ================
# Table Sugar
# ================

func getOrPut*[K,V](self: var SortedTable[K,V], key: K, val: sink V): lent V =
  mixin cmp
  let i = self.lowerIdx(key)
  if i == self.keys.len or cmp(self.keys[i], key) != 0:
    self.keys.insert(key, i)
    self.vals.insert(val, i)
  self.vals[i]

func getOr*[K,V](self: SortedTable[K,V], key: K, val: V): V =
  let i = self.indexOf(key)
  if i == -1: val else: self.vals[i]

func contains*[K,V](self: SortedTable[K,V], key: K): bool =
  self.indexOf(key) != -1

iterator items*[K,V](self: SortedTable[K,V]): lent V =
  for v in self.vals:
    yield v

iterator pairs*[K,V](self: SortedTable[K,V]): Entry[lent K, lent V] =
  for i in 0 ..< self.keys.len:
    yield (self.keys[i], self.vals[i])

func `[]`*[K,V](self: SortedTable[K,V], key: K): lent V =
  self.get(key)

func `[]=`*[K,V](self: var SortedTable[K,V], key: sink K, val: sink V) =
  self.put(key, val)

# ================
# Sorted Set
# ================

type
  SortedSet*[T] {.byref.} = object
    data: seq[T]

func toSortedSet*[T](self: openArray[T], sorted = false): SortedSet[T] =
  mixin cmp
  result.data = @self
  if not sorted:
    result.data.sort(cmp)

func toSortedSet*[T](self: sink seq[T], sorted = false): SortedSet[T] =
  mixin cmp
  result.data = self
  if not sorted:
    result.data.sort(cmp)

func data*[T](self: SortedSet[T]): lent seq[T] =
  self.data

func lowerIdx[T](self: SortedSet[T], val: T): int =
  ## the first index whose member is not below val
  mixin cmp
  self.data.lowerBound(val, cmp)

func indexOf*[T](self: SortedSet[T], val: T): int =
  ## val's index, or -1 when it isn't a member
  mixin cmp
  let i = self.lowerIdx(val)
  if i < self.data.len and cmp(self.data[i], val) == 0: i else: -1

func contains*[T](self: SortedSet[T], val: T): bool =
  self.indexOf(val) != -1

func incl*[T](self: var SortedSet[T], val: sink T) =
  mixin cmp
  let i = self.lowerIdx(val)
  if i < self.data.len and cmp(self.data[i], val) == 0: return
  self.data.insert(val, i)

func excl*[T](self: var SortedSet[T], val: T) =
  let i = self.indexOf(val)
  if i != -1:
    self.data.delete(i)

func getOr*[T](self: SortedSet[T], a, b: T): T =
  let i = self.indexOf(a)
  if i == -1: b else: self.data[i]

iterator items*[T](self: SortedSet[T]): lent T =
  for e in self.data:
    yield e

func `[]=`*[T](self: var SortedSet[T], val: sink T, included: bool) =
  if included: self.incl val
  else: self.excl val

func len*[T](self: SortedSet[T]): Natural =
  self.data.len

func low*[T](self: SortedSet[T]): lent T =
  self.data[0]

func high*[T](self: SortedSet[T]): lent T =
  self.data[self.data.len - 1]

# ================
# Record
# ================
type
  Record*[T] = object
    head: ref T
    data: seq[T]

proc toRecord*[T](self: sink seq[T]): Record[T] =
  doAssert self.len != 0
  result.head = new T
  result.head[] = self[0]
  result.data = self[1..^1]

when isMainModule:
  import std/random

  block:
    const N = 10_000
    var els: array[N, Pair[int]]
    for i in 0..<N:
      els[i] = (N.rand, N.rand)

    var tab = els.toSortedTable

    for _ in 1..1_000:
      tab[N.rand] = N.rand
      tab.delete N.rand

    doAssert tab.keys.isSorted

    # values stay with their keys through sorting, puts and deletes
    var byKey = toSortedTable(@[3, 1, 2], @["three", "one", "two"])
    doAssert byKey.keys == @[1, 2, 3] and byKey.vals == @["one", "two", "three"]
    byKey[0] = "zero"
    byKey[2] = "TWO"
    byKey.delete 3
    doAssert byKey.keys == @[0, 1, 2] and byKey.vals == @["zero", "one", "TWO"]
    doAssert byKey[1] == "one" and byKey.getOr(9, "none") == "none"
    doAssert byKey.getOrPut(5, "five") == "five" and byKey.keys == @[0, 1, 2, 5]

    echo "low: ", tab.low
    echo "high: ", tab.high

  block:
    const N = 10_000
    var els: array[N, int]
    for i in 0..<N:
      els[i] = N.rand
      

    var tab = els.toSortedSet

    for _ in 1..1_000:
      tab[N.rand] = bool.rand
      tab.excl N.rand
    
    doAssert tab.data.isSorted
    echo "low: ", tab.low
    echo "high: ", tab.high