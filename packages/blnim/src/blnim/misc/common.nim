{.experimental: "strictFuncs".}

import ../values
export values

func file*[T](contents: T; info = nilValue()): Value =
  ## (file #[contents] info)
  record(sym"file", bytes(contents), info)

func directory*(files: sink seq[Value]; info = nilValue()): Value =
  ## (directory #{files} info)
  record(sym"directory", set(files), info)
