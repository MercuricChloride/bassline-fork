import core/[shared, builders, codec, reader]

template rv*(s: string): Value =
  readValue(s)

type SomeValue* = Value | ValueView

export shared, builders, codec, reader