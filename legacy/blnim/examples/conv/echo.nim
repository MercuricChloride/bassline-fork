## Echoes CE from stdin to stdout: `input` says each value into a
## conversation, and `output`, who is in it too, writes what it hears.

import bl/conv
import bl/conv/stdio

let pipe = Conversation()
input.join pipe
output.join pipe
try: waitFor input.done
finally: waitFor output.flush
