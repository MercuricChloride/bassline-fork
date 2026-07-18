{.experimental: "strictFuncs".}

import ../dialect
export dialect

type
  BlFileInfo* {.blDict.} = object
    name*: Option[string]
    zip*: Option[Sym]

  BlFile* {.blRecord: "file".} = object
    contents*: seq[byte]
    info*: Option[BlFileInfo]

  Directory* {.blRecord: "directory".} = object
    entries* {.blSet.}: seq[Value]
    info*: Option[BlFileInfo]

  Digest* {.blRecord: "digest".} = object
    algo*: Sym
    hash*: seq[byte]

func toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], addr s[0], s.len)