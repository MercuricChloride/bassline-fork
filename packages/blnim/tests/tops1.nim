import std/[unittest]
import bl/[core, ops]
import bl/lib/[blmacro]

template isSimilar(a, b: string): untyped =
  similar(readValue(a), readValue(b))

suite "similar":
  test "atoms by kind and mark":
    check isSimilar("1", "2")
    check isSimilar("\"a\"", "\"\"")
    check not isSimilar("a", "\"a\"")
    check not isSimilar("a!", "a")
  test "an empty frame fits any frame of its kind":
    check isSimilar("[1 2 3]", "[]")
    check isSimilar("(file a b)","(file)")
    check isSimilar("{a: 1}", "{:}")
    check isSimilar("{1 2}", "{}")
  test "lists and records: a prefix, positions by shape":
    check isSimilar("[1 x]", "[2 y]")
    check not isSimilar("[1]", "[0 0]")
    check isSimilar("(file \"n\" 0xff 42)", "(file \"\" 0xff)")
    check not isSimilar("(dir foo)", "(file)")
  test "dicts: keys required, values by shape, extras ignored":
    check isSimilar(
      "{a: 1 b: x}",
      "{a: 0}"
    )
    check not isSimilar(
      "{a: x}",
      "{a: 0}"
    )
    check not isSimilar(
      "{b: 1}",
      "{a: 0}"
    )
  test "sets: members literal":
    check isSimilar("{1 2 3}", "{2}")
    check not isSimilar("{1 2 3}", "{0}")
    check not isSimilar("{\"x\" 7}", "{\"\"}")