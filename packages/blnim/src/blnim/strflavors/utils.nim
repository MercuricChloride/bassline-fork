## This template implements a small set
## of default procedures for our distinct
## string types
template strDefaults*(T: typedesc) =
  func len*(s: T): int {.borrow.}
  func `==`*(a, b: T): bool {.borrow.}
  func `==`*(a: T, b: string): bool = string(a) == b
  func `==`*(a: string, b: T): bool = a == string(b)
  func `cmp`*(a, b: T): int {.borrow.}
  func `$`*(a: T): string {.borrow.}
  func toString*(s: T): string =
    string(s)
