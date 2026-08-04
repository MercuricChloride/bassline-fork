include pkg/prelude
import std/[tables, sets]
import ./util

type
  MemoryStore* = ref object
    algos: HashSet[string]
    stores: Table[(string, string), Value]
  
proc memoryStore*(): MemoryStore =
  MemoryStore(stores: initTable[(string, string), Value]())

proc keyFor(d: Digest): (string, string) =
  ($d.algo, hexName(d.hash))

proc has*(ms: MemoryStore, d: Digest): bool =
  ms.stores.hasKey(keyFor d)

proc put*(ms: MemoryStore, v: sink Value): Digest =
  let 
    d = digest v
    k = keyFor d
  if not ms.has d:
    ms.stores[k] = v
  ms.algos.incl k[0]
  return d

proc get*(ms: MemoryStore, d: Digest): Option[Value] =
  if ms.has(d):
    some ms.stores[keyFor d]
  else:
    none Value

iterator stored*(ms: MemoryStore): Digest =
  for (algo, hash) in ms.stores.keys:
    yield Digest(algo: Sym(algo), hash: unHexName(hash))