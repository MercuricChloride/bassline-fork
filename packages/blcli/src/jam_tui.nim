## bl jam's terminal: the rooms of a jam, to read and to speak in
##
## What it shows are searches over what the jam has told it: a room is
## the answers to its question, in the order the jam heard them; who is
## here is the here and gone answers read in turn. What it says waits,
## dim, until the jam tells it back; one the jam never tells back is shown
## as not heard.

import std/[algorithm, options, sequtils, strutils, tables, termios, terminal, times, unicode]
import posix except Time
import harness, jam_client
import bl/[core, queries]
import bl/lib/jam

const
  Reset = "\e[0m"
  Bold = "\e[1m"
  Dim = "\e[2m"
  Red = "\e[31m"
  BoldRed = "\e[1;31m"
  Bar = "\e[1;97;41m"        # white on red: the header
  Current = "\e[1;31;107m"   # red on white: the room shown
  NotHeardAfter = 5.0        # seconds before a message said is not heard

type
  Seg = tuple[text, style: string]
  Row = seq[Seg]

  Said = object
    ## a message said here, until the jam tells it back
    room: Value
    kept: Value
    text: string
    at: float

  Page = ref object
    ## a room as the terminal keeps it: what was heard there, each message
    ## read once as it came and laid out once for the width shown
    heard: seq[Heard]           # in the jam's order
    byDigest: Table[string, Heard]  # by the digest (re …) names, as text
    flat: seq[Row]              # the rows of the first `laid` messages
    laid, width: int

  Tui = ref object
    c: Client
    at: Place
    place: string
    tried: float               # when it last dialled the jam
    rooms: seq[Value]
    current: int
    unread: seq[int]
    input: seq[Rune]
    cursor: int
    killed: seq[Rune]          # what was last cut from the input, to put back
    scroll: int
    shown: int                 # the rows the room had when last drawn
    pages: Table[string, Page] # each room heard, by its text
    here: string               # who is here, as last worked out
    hereKnown: bool
    notice: string
    said: seq[Said]
    keys: string               # bytes of a key not yet whole
    pasting: bool
    paste: string              # what is being pasted, until it is whole
    quit, dirty: bool

# ================ what a terminal shows ================

type WChar {.importc: "wchar_t", header: "<wchar.h>".} = int32

proc wcwidth(c: WChar): cint {.importc, header: "<wchar.h>".}

proc utf8Locale() =
  ## wcwidth measures by the locale's character set, so it must be UTF-8
  for name in ["", "C.UTF-8", "en_US.UTF-8"]:
    let set = setlocale(LC_CTYPE, name.cstring)
    if set != nil and ($set).toLowerAscii.replace("-", "").endsWith("utf8"):
      return

proc cell(r: Rune): string =
  ## what a rune shows as: a control is never sent to the terminal
  let c = r.int
  if c == 9: "    "
  elif c < 0x20 or c == 0x7f: "^" & char(c xor 0x40)
  elif c in 0x80 .. 0x9f: "�"
  else: $r

proc columns(r: Rune): int =
  ## the columns a rune takes, shown as its cell
  let c = r.int
  if c == 9: 4
  elif c < 0x20 or c == 0x7f: 2
  elif c in 0x80 .. 0x9f: 1
  else:
    let w = wcwidth(WChar(c))
    if w < 0: 1 else: w

proc columns(s: string): int =
  for r in s.runes: result += columns(r)

proc fit(s: string, width: int): string =
  ## `s` cut to `width` columns, with … where it was cut
  if columns(s) <= width: return s
  var left = width - 1
  for r in s.runes:
    if columns(r) > left: break
    result.add r
    left -= columns(r)
  result.add "…"

proc wrap(s: string, width: int): seq[string] =
  ## `s` in lines of at most `width` columns, broken at spaces where it
  ## can be
  for para in s.splitLines:
    let line = para.toRunes
    var start = 0
    while true:
      var (j, cols, space) = (start, 0, -1)
      while j < line.len and cols + columns(line[j]) <= width:
        if line[j] == Rune(' '): space = j
        cols += columns(line[j])
        inc j
      if j >= line.len:
        result.add $line[start ..< j]
        break
      let cut = if line[j] == Rune(' '): j
                elif space > start: space
                else: max(j, start + 1)
      result.add $line[start ..< cut]
      start = cut
      while start < line.len and line[start] == Rune(' '): inc start
      if start >= line.len: break
  if result.len == 0: result.add ""

# ================ what a room shows ================

proc label(room: Value): string =
  if room.kind == bRec and room.items.len == 2 and room.head == ForQ:
    "@" & nameOf(room.items[1])
  elif room.kind == bSym: "#" & room.text
  else: $room

proc isMe(t: Tui, id: Value): bool =
  sharesIdentity(id, t.c.speaker.by)

proc forMe(t: Tui, said: Value): bool =
  said.isFor(t.c.speaker.by)

proc body(said: Value): Seg =
  ## what a message says, as text when it is text
  let s = said.answer(SaidQ)
  if s.isNone: ($said, Dim)
  elif s.get.kind == bText: (s.get.text, "")
  else: ($s.get, Red)

proc clock(said: Value): string =
  let at = said.answer(AtQ)
  if at.isNone or at.get.kind != bNum or not at.get.num.isInt: return "     "
  fromUnix(at.get.num.toInt div 1000).local.format("HH:mm")

proc take(p: Page, h: Heard) =
  ## keeps a message in its place by rank, once
  let i = p.heard.lowerBound(h, (a, b: Heard) => cmp(a.rank, b.rank))
  if i < p.heard.len and p.heard[i].rank == h.rank: return
  if i < p.heard.len:                       # came out of order: lay out again
    p.laid = 0
    p.flat.setLen 0
  p.heard.insert(h, i)
  p.byDigest[$h.digestOf] = h

proc page(t: Tui, room: Value): Page =
  ## what the terminal keeps of `room`, begun from what the line was told
  let k = $room
  if k notin t.pages:
    let p = Page()
    for h in t.c.local.heardIn(room): p.take h
    t.pages[k] = p
  t.pages[k]

proc rowsOf(t: Tui, h: Heard, room: Page, width: int): seq[Row] =
  ## a message as rows: when, where the jam heard it, who, and what they
  ## said, then what it answers
  let said = h.said
  let by = said.answer(ByQ)
  if by.isNone:                             # not a message: shown as it is
    for i, line in wrap($said, max(10, width - 12)):
      result.add @[((if i == 0: "      #" & alignLeft($h.rank, 5) else: spaces(12)), Dim),
                   (line, Dim)]
    return
  var who = nameOf(by.get)
  if h.vouched: who.add "✓"
  elif h.signer.isSome: who.add "?"
  let lead = clock(said) & " #" & alignLeft($h.rank, 4) & " "
  let pad = columns(lead) + columns(who) + 2
  let (text, style) = body(said)
  let mark = if t.forMe(said) and not t.isMe(by.get): BoldRed else: Dim
  for i, line in wrap(text, max(10, width - pad)):
    if i == 0:
      result.add @[(lead, mark),
                   (who, (if t.isMe(by.get): BoldRed else: Bold)),
                   ("  " & line, style)]
    else: result.add @[(spaces(pad) & line, style)]
  for d in said.answers(ReQ):
    var answered = "   ↳ something not heard here"
    if $d in room.byDigest:
      let other = room.byDigest[$d]
      let lines = body(other.said).text.splitLines
      answered = "   ↳ #" & $other.rank & " " &
        nameOf(other.said.answer(ByQ).get(sym"?")) & ": " & lines[0] &
        (if lines.len > 1: " …" else: "")
    result.add @[(spaces(columns(lead)) & fit(answered, max(10, width - columns(lead))), Dim)]

proc laidOut(t: Tui, width: int): Page =
  ## the room shown with its messages as rows at `width`: each is laid
  ## out once, as it comes, and again only when the width changes
  result = t.page(t.rooms[t.current])
  if result.width != width:
    result.width = width
    result.laid = 0
    result.flat.setLen 0
  while result.laid < result.heard.len:
    result.flat.add t.rowsOf(result.heard[result.laid], result, width)
    inc result.laid

proc waiting(t: Tui, width: int): seq[Row] =
  ## what was said in the room shown and hasn't been told back
  let room = t.rooms[t.current]
  for s in t.said:
    if s.room != room: continue
    let late = epochTime() - s.at > NotHeardAfter
    let lead = (if late: "not heard  " else: "saying…   ") & "  "
    for i, line in wrap(s.text, max(10, width - 14)):
      result.add @[((if i == 0: lead else: spaces(columns(lead))), (if late: Red else: Dim)),
                   (line, Dim)]

# ================ drawing ================

proc put(o: var string, row: int, segs: Row, width: int) =
  ## a screen row, cut to `width` columns
  o.add "\e[" & $row & ";1H\e[2K"
  var left = width
  for (text, style) in segs:
    if left <= 0: break
    var shown = ""
    for r in text.runes:
      if columns(r) > left:
        shown.add spaces(left)
        left = 0
        break
      shown.add cell(r)
      left -= columns(r)
    o.add style & shown & Reset

proc layout(input: seq[Rune], width: int): seq[int] =
  ## where each row of the input begins: wrapped to `width` columns at
  ## spaces where it can be, and broken where it breaks
  result = @[0]
  var (cols, space) = (0, -1)
  for i, r in input:
    if r == Rune('\n'):
      result.add i + 1
      (cols, space) = (0, -1)
      continue
    if cols + columns(r) > width:
      let start = if space >= result[^1]: space + 1 else: i
      result.add start
      (cols, space) = (columns($input[start ..< i]), -1)
    if r == Rune(' '): space = i
    cols += columns(r)

proc draw(t: Tui) =
  let (width, height) = terminalSize()
  var o = "\e[?25l"
  var header: Row = @[(" jam · " & t.place & " · " & $t.c.speaker.name & "  ", Bar)]
  for i, room in t.rooms:
    let n = if t.unread[i] > 0: "(" & $t.unread[i] & ")" else: ""
    header.add (" " & label(room) & n & " ", (if i == t.current: Current else: Bar))
  header.add (spaces(width), Bar)
  o.put(1, header, width)
  # the input at the bottom, wrapped, at most a third of the screen and
  # always the cursor's row
  let starts = layout(t.input, width - 3)
  var at = starts.high
  while starts[at] > t.cursor: dec at
  let typing = min(starts.len, max(1, height div 3))
  let top = max(0, min(starts.len - typing, at))
  # a notice above the status, up to a third of the screen of it
  var notice = if t.notice.len > 0: wrap(t.notice, width) else: @[]
  let most = max(3, height div 3)
  if notice.len > most:
    notice.setLen most
    notice[^1] = fit(notice[^1], width - 1) & "…"
  # the room, the newest at the bottom; scrolled back, it stays put as
  # rows come
  let area = max(1, height - 2 - notice.len - typing)
  let room = t.laidOut(width)
  let late = t.waiting(width)
  let count = room.flat.len + late.len
  if t.scroll > 0: t.scroll += count - t.shown
  t.shown = count
  t.scroll = max(0, min(t.scroll, count - area))
  let last = count - t.scroll
  let first = max(0, last - area)
  let pad = area - (last - first)
  for i in 0 ..< area:
    let r = first + i - pad
    if i < pad or r >= last: o.put(2 + i, @[], width)
    elif r < room.flat.len: o.put(2 + i, room.flat[r], width)
    else: o.put(2 + i, late[r - room.flat.len], width)
  for i, line in notice:
    o.put(2 + area + i, @[(line, Red)], width)
  if not t.hereKnown:
    t.here = t.c.local.who.mapIt(nameOf(it)).join(" ")
    t.hereKnown = true
  let here = t.here
  let on = called(t.c.jam)
  var status = (if on.len > 0: on & " · " else: "") & label(t.rooms[t.current]) &
               " · here: " & here
  if t.scroll > 0: status.add " · ↑" & $t.scroll
  if t.c.closed:
    let other = called(t.c.elsewhere)
    status.add(if t.c.elsewhere.isSome:
                 " · " & (if other.len > 0: other else: "another jam") & " is at " &
                 t.place & " now; dialling again for this one"
               else: " · the jam has gone; dialling again")
  o.put(height - typing, @[(fit(status, width), Dim)], width)
  for i in 0 ..< typing:
    let r = top + i
    var line = $t.input[starts[r] ..< (if r < starts.high: starts[r + 1] else: t.input.len)]
    line.removeSuffix('\n')
    o.put(height - typing + 1 + i, @[((if r == 0: "> " else: "  "), BoldRed), (line, "")], width)
  o.add "\e[" & $(height - typing + 1 + at - top) & ";" &
    $(3 + columns($t.input[starts[at] ..< t.cursor])) & "H\e[?25h"
  stdout.write o
  stdout.flushFile()
  t.dirty = false

# ================ speaking ================

proc open(t: Tui, room: Value) =
  ## shows `room`, asking the jam for it if it hasn't yet
  let i = t.rooms.find(room)
  if i >= 0:
    t.current = i
  else:
    t.rooms.add room
    t.unread.add 0
    t.current = t.rooms.high
    t.c.ask room
    if not (room.kind == bRec and room.items.len == 2 and room.head == ForQ):
      discard t.c.put(RoomsQ, room)
  t.unread[t.current] = 0
  t.scroll = 0

proc mentions(text: string): seq[Value] =
  ## the names a text mentions with @. @here is read as all: nobody goes
  ## by here, so said for here it would reach no one
  for word in strutils.splitWhitespace(text):
    if word.len > 1 and word[0] == '@':
      let name = sym(word[1 .. ^1].strip(chars = {',', '.', ':', ';', '!', '?'}))
      result.add(if name == sym"here": AllName else: name)

proc speak(t: Tui, room, said: Value, text: string, re: seq[Value] = @[]) =
  let m = t.c.speaker.message(said, re, mentions(text))
  let kept = t.c.put(room, m)
  t.said.add Said(room: room, kept: kept, text: text, at: epochTime())

proc roomArg(s: string): Value =
  readValue(s.strip(chars = {'#', ' '}))

proc command(t: Tui, line: string) =
  let (cmd, rest) = block:
    let parts = line.split(maxsplit = 1)
    (parts[0], if parts.len > 1: parts[1] else: "")
  let room = t.rooms[t.current]
  try:
    case cmd
    of "/join", "/j": t.open(roomArg(rest))
    of "/leave":
      if t.rooms.len > 1:
        t.rooms.delete t.current
        t.unread.delete t.current
        t.current = min(t.current, t.rooms.high)
    of "/msg", "/m":
      let parts = rest.split(maxsplit = 1)
      if parts.len < 2: t.notice = "/msg NAME TEXT"
      else:
        let to = initRec(@[ForQ, sym(parts[0])])
        t.open(to)
        t.speak(to, toValue(parts[1]), parts[1])
    of "/re":
      let parts = rest.split(maxsplit = 1)
      let n = parseInt(parts[0].strip(chars = {'#'}))
      let heard = t.page(room).heard
      let i = heard.lowerBound(n, (h: Heard, rank: int) => cmp(h.rank, rank))
      if i >= heard.len or heard[i].rank != n: t.notice = "nothing heard as #" & $n & " here"
      elif parts.len < 2: t.notice = "/re N TEXT"
      else: t.speak(room, toValue(parts[1]), parts[1], @[heard[i].digestOf])
    of "/say":
      t.speak(room, readValue(rest), rest)
    of "/who":
      t.notice = "here: " & t.c.local.who.mapIt(nameOf(it)).join(", ")
    of "/rooms":
      let rooms = t.c.local.heardIn(RoomsQ).maps(label(it.said)).toSeq
      t.notice = "rooms: " & rooms.join(" ")
    of "/quit", "/q": t.quit = true
    of "/help", "/h":
      t.notice = "/join ROOM  /leave  /msg NAME TEXT  /re N TEXT  /say VALUE  /who  /rooms  /quit · " &
        "tab: next room · ↑↓ or the wheel: scroll · pgup/pgdn: a page · m-v/c-v: half a page · esc: back to the newest · " &
        "alt-return or ctrl-j: a new line · alt-←→: a word · ctrl-a/e, ctrl-u/k/w, ctrl-y as in a shell"
    else: t.notice = "no command " & cmd & " (/help)"
  except ValueError as e:
    t.notice = e.msg

proc submit(t: Tui) =
  let line = $t.input
  t.input.setLen 0
  t.cursor = 0
  t.notice = ""
  if line.strip.len == 0: return
  if line.startsWith("/"): t.command(line)
  else: t.speak(t.rooms[t.current], toValue(line), line)
  t.scroll = 0

# ================ hearing ================

proc heard(t: Tui, h: Heard) =
  ## the jam told something: what it said is no longer waiting, and a room
  ## not shown counts it
  t.said.keepItIf(not (it.room == h.q and it.kept == h.answer))
  t.page(h.q).take h
  if h.q in [HereQ, GoneQ]: t.hereKnown = false
  let by = h.said.answer(ByQ)
  if h.q == HereQ and by.isSome and not t.isMe(by.get):
    t.notice = nameOf(by.get) & " is here"
  elif h.q == GoneQ and by.isSome and not t.isMe(by.get):
    t.notice = nameOf(by.get) & " is gone"
  let i = t.rooms.find(h.q)
  if i >= 0 and i != t.current: inc t.unread[i]
  if by.isSome and t.forMe(h.said) and not t.isMe(by.get) and i != t.current:
    t.notice = nameOf(by.get) & " in " & label(h.q) & ": " & body(h.said).text
  t.dirty = true

# ================ keys ================

proc lineStart(t: Tui): int =
  result = t.cursor
  while result > 0 and t.input[result - 1] != Rune('\n'): dec result

proc lineEnd(t: Tui): int =
  result = t.cursor
  while result < t.input.len and t.input[result] != Rune('\n'): inc result

proc wordBack(t: Tui): int =
  result = t.cursor
  while result > 0 and t.input[result - 1].isWhiteSpace: dec result
  while result > 0 and not t.input[result - 1].isWhiteSpace: dec result

proc wordOn(t: Tui): int =
  result = t.cursor
  while result < t.input.len and t.input[result].isWhiteSpace: inc result
  while result < t.input.len and not t.input[result].isWhiteSpace: inc result

proc cut(t: Tui, a, b: int) =
  ## takes the input from `a` to `b` out, kept to put back with ctrl-y
  if b > a:
    t.killed = t.input[a ..< b]
    t.input = t.input[0 ..< a] & t.input[b ..< t.input.len]
  t.cursor = a

proc typed(t: Tui, text: string) =
  ## text put in at the cursor: what is pasted keeps its tabs and line
  ## breaks, and other controls are left out
  let rs = text.replace("\r\n", "\n").replace('\r', '\n').toRunes.filterIt(
    it.int >= 0x20 and it.int != 0x7f and it.int notin 0x80 .. 0x9f or
    it == Rune('\n') or it == Rune('\t'))
  t.input.insert(rs, t.cursor)
  t.cursor += rs.len
  t.dirty = true

proc key(t: Tui, k: string) =
  ## a key by name: a control as the byte it sends, the rest as `left`,
  ## `alt-b`, `shift-pgup`
  let k = if k.endsWith("pgup"): "pgup" elif k.endsWith("pgdn"): "pgdn" else: k
  let page = max(1, terminalSize().h - 4)
  case k
  of "\r": t.submit()
  of "\n", "alt-return": t.typed("\n")
  of "\x7f", "\b":
    if t.cursor > 0:
      t.input.delete(t.cursor - 1)
      dec t.cursor
  of "delete":
    if t.cursor < t.input.len: t.input.delete(t.cursor)
  of "\x04":
    if t.input.len == 0: t.quit = true
    elif t.cursor < t.input.len: t.input.delete(t.cursor)
  of "left", "\x02": t.cursor = max(0, t.cursor - 1)
  of "right", "\x06": t.cursor = min(t.input.len, t.cursor + 1)
  of "alt-left", "ctrl-left", "alt-b": t.cursor = t.wordBack
  of "alt-right", "ctrl-right", "alt-f": t.cursor = t.wordOn
  of "home", "cmd-left", "\x01": t.cursor = t.lineStart
  of "end", "cmd-right", "\x05": t.cursor = t.lineEnd
  of "\x15": t.cut(t.lineStart, t.cursor)
  of "\x0b": t.cut(t.cursor, t.lineEnd)
  of "\x17", "alt-backspace": t.cut(t.wordBack, t.cursor)
  of "alt-d", "alt-delete": t.cut(t.cursor, t.wordOn)
  of "\x19": t.typed($t.killed)
  of "\t", "\x0e": t.open(t.rooms[(t.current + 1) mod t.rooms.len])
  of "shift-tab", "\x10": t.open(t.rooms[(t.current + t.rooms.len - 1) mod t.rooms.len])
  of "up": t.scroll += 1
  of "down": t.scroll = max(0, t.scroll - 1)
  of "pgup": t.scroll += page
  of "pgdn": t.scroll = max(0, t.scroll - page)
  of "alt-v": t.scroll += max(1, page div 2)
  of "\x16": t.scroll = max(0, t.scroll - max(1, page div 2))
  of "cmd-up": t.scroll = int.high div 2
  of "cmd-down": t.scroll = 0
  of "esc":
    t.scroll = 0
    t.notice = ""
  of "paste":
    t.pasting = true
    t.paste = ""
  of "\x03": t.quit = true
  else: discard
  t.dirty = true

const Mods = ["shift-", "alt-", "ctrl-", "cmd-"]

proc named(final: char, params: string): string =
  ## the name of the key a CSI or SS3 sequence stands for, with its
  ## modifiers, or "" for one that stands for nothing here
  let ps = params.split(';')
  result = case final
    of 'A': "up"
    of 'B': "down"
    of 'C': "right"
    of 'D': "left"
    of 'H': "home"
    of 'F': "end"
    of 'Z': "shift-tab"
    of '~':
      case ps[0]
      of "1", "7": "home"
      of "4", "8": "end"
      of "3": "delete"
      of "5": "pgup"
      of "6": "pgdn"
      of "200": "paste"
      else: ""
    else: ""
  if result.len > 0 and ps.len > 1:
    let m = try: parseInt(ps[1]) - 1 except ValueError: 0
    for i, m1 in Mods:
      if (m and (1 shl i)) != 0: result = m1 & result

proc whole(text: string): int =
  ## how much of `text` is whole characters: the rest waits for more
  var k = text.high
  while k >= 0 and k > text.len - 4 and (text[k].ord and 0xC0) == 0x80: dec k
  if k >= 0 and text[k].ord >= 0xC0 and
     text.len - k < (if text[k].ord >= 0xF0: 4 elif text[k].ord >= 0xE0: 3 else: 2):
    k
  else: text.len

proc keysIn(t: Tui, bytes: string) =
  ## the keys in what the terminal sent: an escape sequence whole, a
  ## control key alone, text as it comes, and what is pasted at once
  t.keys.add bytes
  let s = t.keys
  var i = 0
  var text = ""
  template flush() =
    if text.len > 0:
      t.typed(text)
      text = ""
  while i < s.len:
    if t.pasting:
      let e = s.find("\e[201~", i)
      if e < 0:
        let held = max(i, s.len - 5)        # maybe the start of the end
        t.paste.add s[i ..< held]
        i = held
        break
      t.paste.add s[i ..< e]
      t.pasting = false
      t.typed(t.paste)
      t.paste = ""
      i = e + 6
      continue
    let b = s[i]
    if b == '\e':
      flush()
      if i + 1 >= s.len: break                # the rest, or esc alone
      case s[i + 1]
      of '[', 'O':
        var j = i + 2
        if s[i + 1] == '[':
          while j < s.len and s[j] notin {'@' .. '~'}: inc j
        if j >= s.len: break                  # wait for the rest
        t.key(named(s[j], s[i + 2 ..< j]))
        i = j + 1
      of '\e':
        t.key("esc")
        inc i
      of '\x7f', '\b':
        t.key("alt-backspace")
        i += 2
      of '\r', '\n':
        t.key("alt-return")
        i += 2
      else:
        t.key("alt-" & s[i + 1])
        i += 2
    elif b < ' ' or b == '\x7f':
      flush()
      t.key($b)
      inc i
    else:
      text.add b
      inc i
  if i < s.len:
    t.keys = s[i .. ^1]
  else:
    t.keys = text[whole(text) .. ^1]
    text.setLen whole(text)
  flush()

proc keysAlone(t: Tui) =
  ## what is left of a key once nothing more comes: an escape alone is
  ## the esc key, an escape and one more an alt key
  if t.pasting or not t.keys.startsWith("\e"): return
  let s = t.keys
  t.keys = ""
  t.key(if s.len == 1: "esc" elif s.len == 2: "alt-" & s[1] else: "")

# ================ running ================

proc keepUp(t: Tui) =
  ## dials the jam again, every two seconds, once it has gone, keeping
  ## what the line before was told and asking again for every room open
  if not t.c.closed or epochTime() - t.tried < 2: return
  t.tried = epochTime()
  let c = try: dial(t.at, t.c.speaker, t.c) except CatchableError: return
  t.c = c
  for room in t.rooms:
    c.ask room
    if not (room.kind == bRec and room.items.len == 2 and room.head == ForQ):
      discard c.put(RoomsQ, room)
  c.hello()
  t.notice = "on the jam again"
  t.dirty = true

var saved: Termios

proc raw() =
  discard tcGetAttr(0, addr saved)
  var t = saved
  t.c_iflag = t.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  t.c_lflag = t.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)
  t.c_cc[VMIN] = char(0)
  t.c_cc[VTIME] = char(0)
  discard tcSetAttr(0, TCSAFLUSH, addr t)
  stdout.write "\e[?1049h\e[?2004h\e[H\e[2J"
  stdout.flushFile()

proc cooked() =
  stdout.write "\e[?25h\e[?2004l\e[?1049l"
  stdout.flushFile()
  discard tcSetAttr(0, TCSAFLUSH, addr saved)

proc run*(t: Tool, a: Args) =
  if not (stdin.isatty and stdout.isatty):
    fail "bl jam needs a terminal; a pipe speaks to a jam with bl reach"
  let place = t.placeFrom(a)
  let c = try: dial(place, t.speakerFrom(a, signs = true))
          except CatchableError as e:
            fail "no jam at " & $place & " (bl jam serve starts one): " & e.msg
  let tui = Tui(c: c, at: place, place: $place, dirty: true)
  c.onHeard = (h: Heard) => tui.heard(h)
  c.hello()
  let rooms = if a.positional.len > 0: a.positional else: @["general"]
  for r in rooms:
    try: tui.open(roomArg(r))
    except ValueError: t.misuse "not a room: " & r
  tui.open(initRec(@[ForQ, c.speaker.name]))
  tui.current = 0
  utf8Locale()
  raw()
  var
    size = terminalSize()
    drawn = 0.0
    keyed = 0.0
    buf = newString(4096)
  try:
    while not tui.quit:
      turn(15)
      tui.keepUp()
      if readable(0):
        let n = posix.read(0, addr buf[0], buf.len)
        if n > 0:
          tui.keysIn(buf[0 ..< n])
          keyed = epochTime()
      elif tui.keys.len > 0 and epochTime() - keyed > 0.05:
        tui.keysAlone()
      let now = terminalSize()
      if now != size or epochTime() - drawn > 1.0:
        size = now
        tui.dirty = true
      if tui.dirty:
        tui.draw()
        drawn = epochTime()
  finally:
    cooked()
    if not tui.c.closed: tui.c.bye()
