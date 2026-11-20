## The bassline text reader for JavaScript. The editor extension builds
## it with `nim js`; it exports `parseBassline(text)`, which answers
## `{values: [...]}`, each value a plain object with `kind` as a string,
## `mark` where set, `text`, `bytes` as a Uint8Array, `items` or `entries`
## as arrays, and `start` and `stop` offsets on the top level values, or
## `{error: message, offset, line, column}`. Dialect blocks read with the
## standard dialects. Sets and dicts keep their written order here; the
## editor does not sort.

import std/[jsffi, strutils]
import petit_parser
import ../core/shared/shared
import ./[text, dialects]

proc toUint8Array(bs: seq[byte]): JsObject {.importjs: "new Uint8Array(#)".}

proc tagged(k: Kind, mark: bool): JsObject =
  result = newJsObject()
  result.kind = cstring($k)
  if mark: result.mark = true

proc jsMake(): Make[JsObject] =
  Make[JsObject](
    atom: proc (k: Kind, payload: sink string, mark: bool): JsObject =
      result = tagged(k, mark)
      if k != bNil: result.text = cstring(payload),
    bytes: proc (b: sink seq[byte], mark: bool): JsObject =
      result = tagged(bBytes, mark)
      result.bytes = toUint8Array(b),
    frame: proc (k: Kind, members: sink seq[JsObject], mark: bool): JsObject =
      result = tagged(k, mark)
      if k == bDict:
        var entries = newSeq[JsObject]()
        var i = 0
        while i + 1 < members.len:
          entries.add @[members[i], members[i + 1]].toJs
          i += 2
        result.entries = entries
      else:
        result.items = members,
    mark: proc (v: sink JsObject): JsObject =
      v.mark = true
      v)

let make = jsMake()

proc document(): TextParser[seq[Token[JsObject]]] =
  let ws = space()
  extendedValue(make, standardDialects(make)).token.trim(ws).star.trim(ws).complete.resolve

let doc = document()

proc parseBassline*(text: cstring): JsObject {.exportc.} =
  let r = doc.parse($text)
  result = newJsObject()
  if r.isSuccess:
    var values = newSeq[JsObject]()
    for t in r.value:
      var v = t.value
      v.start = t.start
      v.stop = t.stop
      values.add v
    result.values = values
  else:
    let (line, column) = Input[string](r.input).source.lineCol(r.pos)
    result.error = cstring(r.message)
    result.offset = r.pos
    result.line = line
    result.column = column

{.emit: "export { parseBassline }".}
