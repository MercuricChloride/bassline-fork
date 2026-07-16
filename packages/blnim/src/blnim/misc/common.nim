{.experimental: "strictFuncs".}

import std/options
import ../values
export values, options

func file*[T](contents: T; info = nilValue()): Value =
  ## (file #[contents] info)
  record(sym"file", bytes(contents), info)

func directory*(files: sink seq[Value]; info = nilValue()): Value =
  ## (directory #{files} info)
  record(sym"directory", set(files), info)

func digest*(alg: string; hash: openArray[byte]): Value =
  ## (digest <alg> #[hash])
  record(sym"digest", sym(alg), bytes(@hash))
