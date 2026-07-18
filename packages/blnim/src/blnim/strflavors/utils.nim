## This template implements a small set
## of default procedures for our distinct
## string types
template strDefaults*(T) =
  func len*(s: T): int {.inject.} =
    string(s).len

  func `==`*(a, b: T): bool {.inject.} =
    string(a) == string(b)

  func `cmp`*(a, b: T): int {.inject.} =
    a.string.cmp(b.string)

  func `$`*(s: T): string {.inject.} =
    s.string

  func toString*(s: T): string {.inject.} = string(s)