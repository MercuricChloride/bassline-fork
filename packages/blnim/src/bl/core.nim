import core/[btree, builders, codec, reader]

template rv*(s: string): Value =
  readValue(s)

type SomeValue* = Value | ValueView

export btree, builders, codec, reader