## Prints, for each file in a directory, the content fs.nim makes of it:
## {NAME: (CONTENT-DIGEST [CHUNK-DIGEST …]) …}. blts's fs tests check
## their cuts and content against it (packages/blts/test/fs-cuts.make.ts).
##
##   nim c -r tests/fscuts.nim DIR

import std/os
import bl/core
import bl/lib/fs

var cut: seq[(Value, Value)]
for kind, path in walkDir(paramStr(1)):
  if kind != pcFile: continue
  let
    data = readFile(path)
    (content, chunks) = contentOf(data.toOpenArrayByte(0, data.high))
  var ds: seq[Value]
  for c in chunks: ds.add digestOf(c)
  cut.add (text(extractFilename(path)), initRec(sym"cut", [digestOf(content), initList(ds)]))
echo initDict(cut)
