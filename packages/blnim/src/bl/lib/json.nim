import std/json
import std/strutils
import ../core
export json

type
  JsonRefusal* = object of CatchableError

template refuse(msg: string) =
  raise newException(JsonRefusal, msg)

template guardJson(cond, msg) =
  if not cond:
    refuse msg

proc toJson*(self: Value): JsonNode =
  result = %* { "kind": $self.kind }
  if self.mark:
    result["mark"] = %* true
  case self.kind
  of bNil: discard
  of bNum:
    result["value"] = %* self.num
  of bText, bSym:
    result["value"] = %* self.text
  of bBytes:
    result["value"] = %* self.bytes.hexString
  of bList, bRec:
    var items = newJArray()
    for val in self.items:
      items.add val.toJson
    result["value"] = %* items
  of bDict:
    var items = newJArray()
    for key, val in self.dict:
      items.add(%* [key.toJson, val.toJson])
    result["value"] = %* items
  of bSet:
    var items = newJArray()
    for val, _ in self.els:
      items.add val.toJson
    result["value"] = %* items

func parseKind(k: string): Kind =
  case k
  of "nil": bNil
  of "number": bNum
  of "text": bText
  of "symbol": bSym
  of "bytes": bBytes
  of "list": bList
  of "record": bRec
  of "dict": bDict
  of "set": bSet
  else:
    refuse "not a valid kind: " & k

proc toValue*(node: JsonNode): Value

func hexBytes(s: string): seq[byte] =
  guardJson s.startsWith("0x"):
    "hexBytes must start with 0x"

  try:
    let raw = parseHexStr(s[2 .. ^1])
    @(raw.toBytes())
  except ValueError:
    refuse "not hex bytes: " & s

proc members(node: JsonNode): seq[Value] =
  if node.kind != JArray:
    refuse "frame members are an array"
  for el in node:
    result.add toValue(el)

proc toValue*(node: JsonNode): Value =
  guardJson node.kind == JObject,
    "value must be an object"
  
  guardJson "kind" in node,
    "value must have a kind"
  
  let k = node["kind"]

  guardJson k.kind == JString,
    "value.kind must be a string"

  let kind = parseKind k.str

  var mark = false
  
  if node.hasKey("mark"):
    let m = node["mark"]
    guardJson m.kind == JBool, "mark must be a bool"
    if m.bval:
      mark = true

  if kind == bNil:
    guardJson not(node.hasKey("value")),
      "nil carries no value"
    return null(mark)
  
  guardJson node.hasKey("value"),
    $kind & " needs a value"

  let v = node["value"]
  
  case kind
  of bNil: discard
  
  of bNum:
    case v.kind
    of JInt: return num(v.getBiggestInt, mark)
    of JString: refuse "integer outside the range this reading holds: " & v.str
    else: refuse "not an integer: " & $v
  
  of bText, bSym:
    guardJson v.kind == JString,
      $kind & " is a string"

    guardJson isValidUtf8(v.str.toBytes),
      "malformed UTF-8 in " & $kind
    if kind == bText:
      return text(v.str, mark)
    else:
      return sym(v.str, mark)

  of bBytes:
    guardJson v.kind == JString:
      "bytes must be a hex string"
    return bytes(hexBytes(v.str), mark)

  of bList:
    return initList(members(v), mark)
  
  of bRec:
    let items = members(v)
    guardJson items.len > 0,
      "record must have a head"
    return initRec(items, mark)
  
  of bDict:
    guardJson v.kind == JArray,
      "dict entries are an array of [key, value] pairs"
    
    result = initDict(mark)

    for entry in v:
      guardJson entry.kind == JArray and entry.len == 2,
        "a dict entry is [key, value]"
      let k = toValue(entry[0])
      guardJson k notin result.dict,
        "duplicate dict key: " & $k
      result.dict[k] = toValue(entry[1])

  of bSet:
    result = initSet(mark)
    for m in members(v):
      if m in result.els:
        refuse "duplicate set member: " & $m
      result.els.incl m

proc fromJson*(text: string): Value =
  ## parse text as json then read as a value
  toValue(parseJson(text))