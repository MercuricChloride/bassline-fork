## The BASSLINE banner `bl` shows a person at a terminal: sharp red
## letters, a thorn on each stem and a point on the A, lit from above in
## cream with a white glint on each point, over a smooth wave that
## tapers at both ends, like the logo's swoosh. Drawn in half blocks, two pixel rows to a line; the
## colours are flat, with no dither, and the wave's edges are softened
## with darker reds where it only partly covers a pixel.

import std/[math, options, os, strutils]

type
  Rgb = tuple[r, g, b: int]
  Tone = enum blank, glint, cream, under, body, edge, faint
    ## glint: a point's tip; cream: an edge lit from above; under: the
    ## underside of a bar or bowl; body: the rest; edge and faint: where
    ## the wave covers a pixel only in part
  ColorMode = enum mono, palette, truecolor

const
  Glyphs = [
  ('B', """
........
........
.X......
XXXXXXX.
.XXX.XXX
.XXX..XX
.XXX..XX
.XXX.XX.
.XXXXX..
.XXX.XX.
.XXX..XX
.XXX..XX
.XXX..XX
.XXX.XXX
.XXXXXX.
XXXXXX.."""),
  ('A', """
....XX....
...XXXX...
..XXXXXX..
..XXXXXX..
.XXX..XXX.
.XXX..XXX.
.XXX..XXX.
.XXX..XXX.
.XXXXXXXX.
.XXXXXXXX.
.XXX..XXX.
.XXX..XXX.
.XXX..XXX.
.XXX..XXX.
.XXX..XXX.
XXXX..XXXX"""),
  ('S', """
........
........
.......X
..XXXXXX
.XXXX..X
XXX.....
XXX.....
XXXX....
.XXXXX..
..XXXXX.
....XXXX
.....XXX
.....XXX
X....XXX
XX..XXX.
XXXXXXX."""),
  ('L', """
........
........
.X......
XXXXX...
.XXX....
.XXX....
.XXX....
.XXX....
.XXX....
.XXX....
.XXX....
.XXX....
.XXX...X
.XXX..XX
.XXXXXXX
XXXXXXXX"""),
  ('I', """
.....
.....
.X...
XXXXX
.XXX.
.XXX.
.XXX.
.XXX.
.XXX.
.XXX.
.XXX.
.XXX.
.XXX.
.XXX.
.XXX.
XXXXX"""),
  ('N', """
..........
..........
X.......X.
XXX....XXX
XXXX...XX.
.XXXX..XX.
.XXXXX.XX.
.XX.XX.XX.
.XX.XXXXX.
.XX..XXXX.
.XX..XXXX.
.XX...XXX.
.XX...XXX.
.XX....XX.
.XX....XX.
XXXX...XX."""),
  ('E', """
........
........
.......X
XXXXXXXX
.XXX..XX
.XXX....
.XXX....
.XXX..X.
.XXXXXX.
.XXX..X.
.XXX....
.XXX....
.XXX....
.XXX...X
.XXX..XX
XXXXXXXX""")]
  GlyphRows = 16
  ToneColor: array[Tone, Rgb] = [(0, 0, 0), (255, 255, 255), (245, 225, 200),
                                 (146, 18, 56), (208, 36, 45), (146, 18, 56),
                                 (90, 17, 54)]
  WaveGap = 2    ## pixel rows between the letters and the wave
  WaveRows = 6

func glyph(c: char): seq[string] =
  for (name, rows) in Glyphs:
    if name == c:
      return rows.splitLines

func compose(word: string): seq[string] =
  ## the word's pixels, a column apart
  result = newSeq[string](GlyphRows)
  for i, c in word:
    for y, line in glyph(c):
      if i > 0: result[y].add '.'
      result[y].add line

func shade(bm: seq[string]): seq[seq[Tone]] =
  ## light from above: top edges cream, a point's tip white, undersides
  ## in shadow, and the bottom edge left the body's red so the weight
  ## stays up
  func ink(x, y: int): bool =
    y in 0 ..< bm.len and x in 0 ..< bm[y].len and bm[y][x] == 'X'
  result = newSeq[seq[Tone]](bm.len)
  for y in 0 ..< bm.len:
    result[y] = newSeq[Tone](bm[y].len)
    for x in 0 ..< bm[y].len:
      if not ink(x, y): continue
      let thin = not ink(x - 1, y) and not ink(x + 1, y)
      result[y][x] =
        if thin and not ink(x, y - 1): glint
        elif thin or not ink(x, y - 1): cream
        elif not ink(x, y + 1) and y < GlyphRows - 2: under
        else: body

func wave(width: int): seq[seq[Tone]] =
  ## a slow wave, a pixel or so thick, that swells in the middle and
  ## thins to nothing at both ends; each pixel's tone is how much of it
  ## the wave covers, sampled on a 4 by 4 grid
  const Samples = 4
  func centre(t: float): float =
    2.7 - 2.2 * sin(2 * PI * 1.5 * t + 0.3) * pow(sin(PI * t), 0.4)
  func thickness(t: float): float =
    0.4 + 1.2 * pow(sin(PI * t), 0.7)
  result = newSeq[seq[Tone]](WaveRows)
  for y in 0 ..< WaveRows:
    result[y] = newSeq[Tone](width)
    for x in 0 ..< width:
      var covered = 0
      for sy in 0 ..< Samples:
        for sx in 0 ..< Samples:
          let
            px = float(x) + (float(sx) + 0.5) / Samples
            py = float(y) + (float(sy) + 0.5) / Samples
            t = px / float(width)
          if abs(py - centre(t)) <= thickness(t) / 2: inc covered
      let share = covered / (Samples * Samples)
      result[y][x] =
        if share >= 0.55: body elif share >= 0.25: edge
        elif share >= 0.1: faint else: blank

func picture(word: string): seq[seq[Tone]] =
  ## the shaded word, a gap, then the wave, in rows made even for the
  ## half blocks
  result = shade(compose(word))
  let width = result[0].len
  for _ in 1 .. WaveGap: result.add newSeq[Tone](width)
  result.add wave(width)
  if result.len mod 2 == 1: result.add newSeq[Tone](width)

const Art = picture("BASSLINE")

func level(c: int): int =
  ## the nearest step of the 256-colour cube: 0, 95, 135, 175, 215, 255
  if c < 48: 0 elif c < 115: 1 else: (c - 35) div 40

func sgr(c: Rgb, mode: ColorMode, background: bool): string =
  let base = if background: "48" else: "38"
  case mode
  of truecolor: "\e[" & base & ";2;" & $c.r & ";" & $c.g & ";" & $c.b & "m"
  of palette:
    "\e[" & base & ";5;" &
      $(16 + 36 * level(c.r) + 6 * level(c.g) + level(c.b)) & "m"
  of mono: ""

func render(mode: ColorMode): string =
  ## each line two pixel rows: a cell is ▀ in the top's colour over the
  ## bottom's, or one half alone; colours are said only when they change
  var fg, bg = none(Rgb)
  proc paint(s: var string, f, b: Option[Rgb], glyph: string) =
    if mode != mono:
      if (f.isNone and fg.isSome) or (b.isNone and bg.isSome):
        s.add "\e[0m"
        fg = none(Rgb)
        bg = none(Rgb)
      if f.isSome and f != fg: s.add sgr(f.get, mode, false)
      if b.isSome and b != bg: s.add sgr(b.get, mode, true)
      fg = f
      bg = b
    s.add glyph
  func color(t: Tone): Option[Rgb] =
    if t == blank or (mode == mono and t in {edge, faint}): none(Rgb)
    else: some(ToneColor[t])
  for row in countup(0, Art.high, 2):
    for x in 0 ..< Art[row].len:
      let (top, bottom) = (color(Art[row][x]), color(Art[row + 1][x]))
      if top.isSome and bottom.isSome:
        result.paint(top, bottom, if mode == mono: "█" else: "▀")
      elif top.isSome:
        result.paint(top, none(Rgb), "▀")
      elif bottom.isSome:
        result.paint(bottom, none(Rgb), "▄")
      else:
        result.paint(none(Rgb), none(Rgb), " ")
    result.paint(none(Rgb), none(Rgb), "\n")

proc banner*(): string =
  ## the banner in as much colour as the terminal says it takes: none
  ## with NO_COLOR set or a dumb terminal, all of it where COLORTERM says
  ## truecolor, the 256-colour cube otherwise
  let mode =
    if existsEnv("NO_COLOR") or getEnv("TERM") in ["", "dumb"]: mono
    elif getEnv("COLORTERM") in ["truecolor", "24bit"]: truecolor
    else: palette
  render(mode)
