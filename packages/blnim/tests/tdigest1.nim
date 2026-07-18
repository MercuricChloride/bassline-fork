import std/unittest
from std/strutils import repeat
import blnim/codec/[digest, encode]
import blnim/misc/common
import checksums/sha2

proc bulkSha256(bs: seq[byte]): array[32, byte] =
  var st = initSha_256()
  if bs.len > 0:
    st.update(cast[ptr UncheckedArray[char]](addr bs[0])
              .toOpenArray(0, bs.len - 1))
  let d = st.digest()
  copyMem(addr result[0], addr d[0], 32)

suite "digest":
  test "streaming sink equals bulk hash of the encoding":
    for v in [nilValue(), num"42", text"hello", mark(sym"f"),
              bytes(@[byte 1, 2, 3]),
              text(repeat('e', 70_000)),
              toValue(BlFile(contents: toBytes"hi")),
              set(num"3", num"1", num"2"),
              dict(@[(sym"a", num"1"), (sym"b", list())]),
              mark(list(sym"q", record(sym"add", num"1", num"2")))]:
      check sha256(v) == bulkSha256(encode(v))

  test "canonicalization means one name per value":
    check sha256(set(num"1", num"2")) == sha256(set(num"2", num"1"))

  test "digest record shape":
    let v = num"1"
    check toValue(Digest(algo: Sym"sha256", hash: @(sha256(v)))) ==
          record(sym"digest", sym"sha256", bytes(@(sha256(v))))
