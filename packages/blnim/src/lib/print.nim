{.experimental: "strictFuncs".}

from std/strutils import join, toHex, toLowerAscii
import std/sequtils
import ../core/values
import ./read

func escaped(s: string, q: char): string =
  for c in s:
    if c == q or c == '\\':
      result.add '\\'
    result.add c

func `$`*(v: Value): string =
  let core =
    case v.kind
    of bNil:
      "nil"
    of bNum:
      $v.num
    of bSym:
      let name = $v.text
      if isBareSpelling(name):
        name
      else:
        "'" & escaped(name, '\'') & "'"
    of bText:
      "\"" & escaped($v.text, '"') & "\""
    of bBytes:
      "0x" & v.bytes.mapIt(it.toHex).join.toLowerAscii
    of bList:
      "[" & v.items.mapIt($it).join(" ") & "]"
    of bRecord:
      "(" & v.items.mapIt($it).join(" ") & ")"
    of bSet:
      "{" & v.elements.mapIt($it).join(" ") & "}"
    of bDict:
      if v.entries.len == 0:
        "{:}"
      else:
        "{" & v.entries.mapIt($it[0] & ": " & $it[1]).join(" ") & "}"
  if not v.marked:
    core
  elif v.isFrame:
    "!" & core
  else:
    core & "!"
