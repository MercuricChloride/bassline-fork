include pkg/prelude
from std/strutils import toHex, toLowerAscii
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
      var hex = "0x"
      for b in v.bytes:
        hex.add b.toHex.toLowerAscii
      hex
    of bList, bRecord:
      var parts = ""
      for c in v.contents:
        if parts.len > 0:
          parts.add ' '
        parts.add $c
      if v.kind == bList:
        "[" & parts & "]"
      else:
        "(" & parts & ")"
    of bSet:
      var parts = ""
      for c in v.contents:
        if parts.len > 0:
          parts.add ' '
        parts.add $c
      "{" & parts & "}"
    of bDict:
      if v.contents.len == 0:
        "{:}"
      else:
        var parts = ""
        for k, val in v.pairs:
          if parts.len > 0:
            parts.add ' '
          parts.add $k
          parts.add ": "
          parts.add $val
        "{" & parts & "}"
  if not v.marked:
    core
  elif v.isFrame:
    "!" & core
  else:
    core & "!"
