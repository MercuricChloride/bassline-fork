import pkg/core/[btree, builders, codec, reader]

template rv*(s: string): Value =
  readValue(s)

export btree, builders, codec, reader