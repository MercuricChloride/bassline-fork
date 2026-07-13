{.experimental: "strictFuncs".}

from std/strutils import join, toHex
import std/sequtils
import values

export values

func `$`*(v: Value): string =
  let prefix = if v.marked: "`" else: ""

  case v.kind
  of bNil:
    prefix & "nil"
  of bNum:
    prefix & $v.num
  of bSym:
    prefix & $v.text
  of bText:
    prefix & "\"" & $v.text & "\""
  of bBytes:
    prefix & "#[" & v.bytes.mapIt($it.toHex).join & "]"
  of bList:
    let items = v.items.mapIt($it).join(" ")
    prefix & "[" & items & "]"
  of bRecord:
    let items = v.items.mapIt($it).join(" ")
    prefix & "(" & items & ")"
  of bSet:
    let elements = v.elements.mapIt($it).join(" ")
    prefix & "#{" & elements & "}"
  of bDict:
    let entries = v.entries.mapIt($it[0] & ": " & $it[1]).join(" ")
    prefix & "{" & entries & "}"
