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
