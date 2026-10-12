## An interface done by the evaluator: groceries.bl is the app, as
## values, and this is a host for it, drawing to a terminal.
##
## The host holds three things: a space that has heard what was said,
## the doers in reach (the base vocabulary, `put` and `ask` over the
## space, and one doer per widget, making its record), and a renderer
## that reads widget records. It asks `!(groceries)`, draws what that
## answers, and keeps each action it drew. An event does the action it
## was drawn for, with what the event gives it (typed text, and the
## occasion), pulling every answer it has, since its acts are done as its
## answers are pulled; and the view is asked again: nothing is kept
## between the two but what the space has heard.
##
## Then it shows the app being changed while it runs. A rule put in a cx
## nearer than the app's own is found first, so the app's rows grow a
## button without the app being touched; and a widget the renderer can't
## draw is drawn as the value it is. (A widget is data to the renderer;
## a call nothing here can do is another thing, and answers nothing.)
##
##   nim c -r examples/lang/ui.nim           a scripted session
##   nim c -r examples/lang/ui.nim -i        click N, type N TEXT, quit

import std/[os, strutils, options]
import bl/lang

let
  here = currentSourcePath().parentDir
  app = readValue(readFile(here / "groceries.bl"))

# ================ widgets ================

type Widget = ref object of Doer
  ## a widget's call, making its record: (HEAD ARG …), arguments done

method answers(d: Widget, v: Value, cx: Cx): Stream[Value] =
  var items = v.items.data
  just initRec(items)

method describe(d: Widget): Value = sym"widget"

const Widgets = ["text", "button", "input", "row", "column"]

# ================ drawing ================

type Drawn = object
  lines: seq[string]
  actions: seq[(string, Value)] ## what each number does, and its label

proc draw(d: var Drawn, w: Value, indent: int, line: var string)

proc drawAll(d: var Drawn, items: openArray[Value], indent: int,
             line: var string) =
  for w in items:
    if w.isKind(bList, unmarked): d.drawAll(w.items.data, indent, line)
    else: d.draw(w, indent, line)

proc flush(d: var Drawn, line: var string) =
  if line.strip.len > 0: d.lines.add line.strip(leading = false)
  line = ""

proc draw(d: var Drawn, w: Value, indent: int, line: var string) =
  let pad = repeat("  ", indent)
  let head = if w.isKind(bRec, unmarked): $w.items[0] else: ""
  case head
  of "text":
    if line.len == 0: line = pad
    line.add w.items[1].text & "  "
  of "button":
    d.actions.add (w.items[1].text, w.items[2])
    if line.len == 0: line = pad
    line.add "[" & $d.actions.len & ": " & w.items[1].text & "]  "
  of "input":
    d.actions.add (w.items[1].text, w.items[2])
    d.flush(line)
    d.lines.add pad & "[" & $d.actions.len & ": " & w.items[1].text & " ____]"
  of "row":
    d.flush(line)
    d.drawAll(w.items.data[1 .. ^1], indent, line)
    d.flush(line)
  of "column":
    d.flush(line)
    let items = w.items.data[1 .. ^1]
    for i, part in items:
      d.drawAll([part], (if i == 0: indent else: indent + 1), line)
      d.flush(line)
  else:
    # nothing here draws it: it is shown as the value it is
    if line.len == 0: line = pad
    line.add $w & "  "

proc drawn(view: Value): Drawn =
  var line = ""
  result.draw(view, 0, line)
  result.flush(line)

# ================ the host ================

type Host = object
  cx: Cx
  space: BVar[Value, Value]
  view: Drawn
  said: int ## occasions so far

proc host(): Host =
  result.space = spaceVar[Value, Value]()
  result.cx = base(unheard = (v: Value) => echo("  (nothing here does ", v, ")"))
  result.cx.install(result.space.sender)
  result.cx.install(result.space.search)
  let widget = Widget()
  for w in Widgets: result.cx.install(sym(w), widget)
  result.cx.install(rules(app.items.data))

proc show(h: var Host, cx: Cx) =
  let v = cx.value(rv"!(groceries)")
  h.view = drawn(v.get(rv"""(text "nothing to show")"""))
  echo ""
  for l in h.view.lines: echo "  ", l

proc drawnAs(h: Host, label, item: string): int =
  ## the number drawn for the action with this label, about this item
  for i, (l, action) in h.view.actions:
    let caught = action.items[^1].dict
    if l == label and sym"it" in caught and caught[sym"it"].items[0] == text(item):
      return i + 1

proc occasion(h: var Host): Value =
  inc h.said
  num(h.said)

proc want(h: var Host, item: string) =
  discard h.space.send(sym"want", initList(@[text(item), h.occasion]))

proc event(h: var Host, cx: Cx, n: int, given: seq[Value]) =
  ## the action drawn as n, done with what the event gives
  if n < 1 or n > h.view.actions.len:
    echo "  (nothing drawn as ", n, ")"
    return
  let (label, action) = h.view.actions[n - 1]
  echo "> ", label, (if given.len > 0: " " & $given[0] else: "")
  for _ in cx.eval(initRec(@[action] & given, mark = true)): discard

when isMainModule:
  var h = host()
  for item in ["oat milk", "eggs", "coffee"]: h.want(item)

  if "-i" in commandLineParams():
    h.show(h.cx)
    for l in stdin.lines:
      let words = l.strip.split(maxsplit = 2)
      if words.len == 0: continue
      case words[0]
      of "quit": break
      of "click": h.event(h.cx, parseInt(words[1]), @[])
      of "type": h.event(h.cx, parseInt(words[1]), @[text(words[2]), h.occasion])
      else: echo "  click N, type N TEXT, quit"
      h.show(h.cx)
  else:
    h.show(h.cx)
    h.event(h.cx, h.drawnAs("got it", "eggs"), @[])
    h.show(h.cx)
    h.event(h.cx, h.view.actions.len, @[text"bread", h.occasion])
    h.show(h.cx)
    h.event(h.cx, h.view.actions.len, @[text"eggs", h.occasion])
    h.show(h.cx)

    echo ""
    echo "an action is a value; the first one drawn:"
    echo "  ", h.view.actions[0][1]

    echo ""
    echo "a nearer rule changes the rows, the app untouched:"
    let nearer = h.cx.within
    nearer.install(rules([rv"""(rule (shape !(item-row it) {it})
      [!(row !(text !(get it! 0)) !(button "got it" !(fn [] [!(put got it!)]))
             !(button "later" !(fn [] [!(put later it!) !(put got it!)]))
             (badge "new"))])"""]))
    h.show(nearer)
    h.event(nearer, h.drawnAs("later", "oat milk"), @[])
    h.show(nearer)
    echo ""
    echo "what the space has heard about later: ", h.space.read(sym"later").toSeq
