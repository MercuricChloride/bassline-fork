import std/[os, times, strformat]
import tinybl

refuseWith BasslineError

useValue Val

template ifof(l, T, body: untyped) =
  if l of T:
    let l = T(l)
    body

layer PointL(x: BNum, y: BNum)

proc point(v: Val): PointL {.reader.} =
  matchValue v:
  of "[$x $y]":
    [x, y].expectAllKind(bNum, unmarked)
    newPointL(x.num, y.num)
  of "(point $x $y)":
    [x, y].expectAllKind(bNum, unmarked)
    newPointL(x.num, y.num)
  else: nil

proc `$`(self: PointL): string =
  fmt"({$self.x},{$self.y})"

layer LineL(points: seq[PointL])

proc line(v: Val): LineL {.reader.} =
  matchValue v:
  of "[&rest]":
    if rest.len == 0:
      return nil
    var points: seq[PointL]
    for each in rest:
      let p = each.attach(PointL)
      if not p.isNil:
        points.add p
      else: return nil
    newLineL(points)
  else: nil

layer FileL(path: string)

proc file(v: Val): FileL {.reader.} =
  matchValue v:
  of "(file $path)":
    path.expectKind({bText, bSym})
    newFileL(path.text)
  of "$path!":
    path.expectKind({bText, bSym})
    let p = path.text.expandTilde
    if p.fileExists: 
      newFileL(path.text)
    else: nil
  else: nil

proc resolve*(self: FileL): string =
  let p = expandTilde(self.path)
  guard fileExists(p), "cannot resolve file"
  readFile(p)

layer StatL(pid: int, dir: string, time: int)

proc onFiles(self: StatL, v: Val): bool {.binder.} =
  ## the pass's stat goes on each value it found a file on
  v.hasLayer(FileL)

let pass = newStatL(
  pid = getCurrentProcessId(),
  dir = getCurrentDir(),
  time = int(now().toTime.toUnix))

let values = bl"""
  [
    [hello (file "~/prg/bassline/data-model.org")]
    [10 [1 2] (file ~/prg/bassline/AGENTS.md)]
    ~/prg/bassline/AGENTS.md!
    [ (point 69 420) [3 4] ]
  ]
"""

for each in values.walk:
  each + PointL + FileL + LineL + pass

for each in values.walk:
  if each.layers.len == 0: continue
  echo "\nfor value: ", each
  for l in each.layers:
    ifof l, PointL:
      echo "  point: ", l[]
    ifof l, FileL:
      echo "  file: ", l.resolve
    ifof l, LineL:
      echo "  line: ", l.points
    ifof l, StatL:
      echo "  stat: ", l[]