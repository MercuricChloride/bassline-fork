import std/unittest
from std/strutils import repeat
import nimcrypto/sha2
import pkg/core
import pkg/lib/obmcommon
import pkg/lib/crypto/digest
import pkg/lib/stores/util


proc bulkSha256(bs: seq[byte]): array[32, byte] =
  var st: sha2.sha256
  st.init()
  if bs.len > 0:
    st.update(bs)
  st.finish().data

suite "digest":
  test "streaming sink equals bulk hash of the encoding":
    for v in [
      nilValue(),
      num"42",
      text"hello",
      mark(sym"f"),
      bytes(@[byte 1, 2, 3]),
      text(repeat('e', 70_000)),
      toValue(BlFile(contents: toBytes"hi")),
      set(num"3", num"1", num"2"),
      dict(@[(sym"a", num"1"), (sym"b", list())]),
      mark(list(sym"q", record(sym"add", num"1", num"2"))),
    ]:
      check sha256(v) == bulkSha256(encode(v))

  test "canonicalization means one name per value":
    check sha256(set(num"1", num"2")) == sha256(set(num"2", num"1"))

  test "digest record shape":
    let v = num"1"
    check toValue(Digest(algo: Sym"sha256", hash: @(sha256(v)))) ==
      record(sym"digest", sym"sha256", bytes(@(sha256(v))))

  test "published vectors anchor both algos":
    # the raw-bytes overloads against third-party answers, so the
    # hashing isn't only ever checked against itself
    let empty = newSeq[byte]()
    check hexName(sha256(empty)) ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check hexName(sha256(toBytes"abc")) ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check hexName(blake2b(empty)) ==
      "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
    check hexName(blake2b(toBytes"abc")) ==
      "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"
