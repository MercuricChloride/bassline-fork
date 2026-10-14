## bl read: the textual syntax to CE, each value as soon as it is certain

import harness

proc readText(s: Source) =
  ## Each value goes out once nothing still to come can change it: a
  ## frame when it closes and something follows, an atom when a
  ## delimiter follows it, the last value when the text ends.
  var
    r: Reader
    buf = newString(ReadChunk)
  while true:
    let n = s.readSome(addr buf[0], buf.len)
    if n == 0:
      break
    r.add buf[0 ..< n]
    try:
      for v in r.items:
        emit v
    except ReadError as e:
      fail s.name & ": " & e.msg
  try:
    for v in r.finish:
      emit v
  except Incomplete as e:
    fail s.name & " ends partway through a value: " & e.msg
  except ReadError as e:
    fail s.name & ": " & e.msg

proc run(t: Tool, a: Args) =
  if a.positional.len == 0:
    readText stdinSource()
  for path in a.positional:
    let s = openSource(path)
    readText s
    s.close()

let tool* = Tool(
  name: "read",
  args: "[FILE…]",
  summary: "the textual syntax to CE, each value as soon as it is certain",
  about: """
Reads text from each FILE in turn, or from stdin with no FILE or for
`-`. A value can't span two files. Text that isn't the syntax is fatal,
after the values before it.""",
  run: run)
