# ## bl: the bassline shell thing

# import std/os
# import core
# import lib/shell

# proc oneShot(sh: var Shell, args: seq[string]): int =
#   ## Each argument is one value when it reads as one, else the text it
#   ## is, so the OS shell's quoting survives: `bl set x "hello world"`
#   var said = initList()
#   for a in args:
#     try:
#       readDocument(a, said.items)
#     except ReadError:
#       said.items.add text(a)
#       discard
#   var refusals = 0
#   sh.onPrint = proc (sh: var Shell, v: Value) =
#     if v.kind == bRec and v.items[0] == sym"refused": inc refusals
#     echo pretty(v, sh.width)
#   sh.hear(said)
#   if refusals > 0: 1 else: 0

# proc main() =
#   var sh = initShell()
#   installBasicWords sh
#   if paramCount() > 0:
#     quit oneShot(sh, commandLineParams())
#   else:
#     run sh

# when isMainModule:
#   main()
