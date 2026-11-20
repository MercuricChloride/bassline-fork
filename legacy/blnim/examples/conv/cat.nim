## Writes the CE values in each file named, one file after another, to
## stdout. With no files it reads stdin.

import std/os
import bl/conv
import bl/conv/stdio

let pipe = Conversation()
output.join pipe
try:
  if paramCount() == 0:
    input.join pipe
    waitFor input.done
  for path in commandLineParams():
    let file = inputFrom(path)
    file.join pipe
    waitFor file.done
finally:
  waitFor output.flush
