import std/[unittest, sequtils, options]
import pkg/core

import lib/obm

type
  ZipMode = enum
    gzip
    tarball

  FileInfo {.blDict.} = object
    name: Option[string]
    zip: Option[ZipMode]

  File {.blRecord: "file".} = object
    contents: seq[byte]
    info: Option[FileInfo]

  FsKind = enum
    fsFile
    fsDir

  FsEntry = object
    case kind: FsKind
    of fsFile: file: File
    of fsDir: dir: Directory

  Directory {.blRecord: "directory".} = object
    entries {.blSet.}: seq[FsEntry]
    info: Option[FileInfo]

  Digest {.blRecord: "digest".} = object
    algo: Sym
    hash: seq[byte]

  Keypair {.blRecord: "keypair".} = object
    scheme: Lit["eddsa-blake2b"]
    seed: array[32, byte]
    public: array[32, byte]

  Signature {.blRecord: "signature".} = object
    scheme: Lit["eddsa-blake2b"]
    sig: array[64, byte]
    public: array[32, byte]

  Signed {.blRecord: "signed".} = object
    value: Value
    signature: Signature

  Dec {.blRecord: "dec".} = object
    m: int
    e: int

  Big {.blRecord: "big".} = object
    n: DecimalString

  Pinned {.blDict.} = object
    algo: Sym
    contentType {.blKey: "content-type".}: Option[Sym]

# a union is one hand-written overload pair; the engine defers to it
func toValue(x: FsEntry): Value =
  case x.kind
  of fsFile:
    toValue(x.file)
  of fsDir:
    toValue(x.dir)

func fromValue(v: Value, T: typedesc[FsEntry]): Option[FsEntry] =
  let f = fromValue(v, File)
  if f.isSome:
    return some FsEntry(kind: fsFile, file: f.get)
  let d = fromValue(v, Directory)
  if d.isSome:
    return some FsEntry(kind: fsDir, dir: d.get)
  none(FsEntry)

# ================ TESTS ================

let
  payload = @[byte 1, 2, 3]
  seed32 = newSeqWith(32, byte 7)
  pub32 = newSeqWith(32, byte 9)
  sig64 = newSeqWith(64, byte 4)

suite "byte parity with the wire spellings":
  test "file, no info":
    let typed = toValue(File(contents: payload))
    let handRolled = record(sym"file", bytes(payload), nilValue())
    check typed == handRolled
    check encode(typed) == encode(handRolled)

  test "file with info dict":
    let typed = toValue(
      File(contents: payload, info: some FileInfo(name: some "a.txt", zip: some gzip))
    )
    let handRolled = record(
      sym"file",
      bytes(payload),
      dict(@[(sym"name", text"a.txt"), (sym"zip", sym"gzip")]),
    )
    check typed == handRolled
    check encode(typed) == encode(handRolled)

  test "directory with set framing":
    let a = File(contents: payload, info: some FileInfo(name: some "a"))
    let b = File(contents: @[byte 9], info: some FileInfo(name: some "b"))
    let typed = toValue(
      Directory(
        entries: @[FsEntry(kind: fsFile, file: a), FsEntry(kind: fsFile, file: b)]
      )
    )
    let handRolled =
      record(sym"directory", values.set(toValue(a), toValue(b)), nilValue())
    check typed == handRolled
    check encode(typed) == encode(handRolled)

  test "digest":
    let typed = toValue(Digest(algo: Sym"sha256", hash: seed32))
    let handRolled = record(sym"digest", sym"sha256", bytes(seed32))
    check typed == handRolled

  test "keypair matches clave's spelling":
    var kp = Keypair()
    for i in 0 ..< 32:
      kp.seed[i] = seed32[i]
      kp.public[i] = pub32[i]
    let typed = toValue(kp)
    let handRolled =
      record(sym"keypair", sym"eddsa-blake2b", bytes(seed32), bytes(pub32))
    check typed == handRolled

  test "signed wraps a nested signature record":
    var s = Signature()
    for i in 0 ..< 64:
      s.sig[i] = sig64[i]
    for i in 0 ..< 32:
      s.public[i] = pub32[i]
    let inner = mark(record(sym"greet", text"hello")) # an actionable payload
    let typed = Signed(value: inner, signature: s).toValue
    let handRolled = record(
      sym"signed",
      inner,
      record(sym"signature", sym"eddsa-blake2b", bytes(sig64), bytes(pub32)),
    )
    check typed == handRolled

suite "recognition":
  test "round trips":
    let f = File(
      contents: payload, info: some FileInfo(name: some "a.txt", zip: some tarball)
    )
    let back = fromValue(toValue(f), File)
    check back.isSome
    check back.get.contents == payload
    check back.get.info.get.name.get == "a.txt"
    check back.get.info.get.zip.get == tarball

  test "keypair shape, exactly clave's checks":
    let good = record(sym"keypair", sym"eddsa-blake2b", bytes(seed32), bytes(pub32))
    let kp = fromValue(good, Keypair)
    check kp.isSome
    check kp.get.seed[0] == byte 7
    check kp.get.public[0] == byte 9

    # wrong scheme literal
    check fromValue(
      record(sym"keypair", sym"rsa", bytes(seed32), bytes(pub32)), Keypair
    ).isNone
    # wrong head
    check fromValue(
      record(sym"keypare", sym"eddsa-blake2b", bytes(seed32), bytes(pub32)), Keypair
    ).isNone
    # wrong seed size
    check fromValue(
      record(sym"keypair", sym"eddsa-blake2b", bytes(seed32[0 ..< 31]), bytes(pub32)),
      Keypair,
    ).isNone
    # extra field: shape is closed
    check fromValue(
      record(sym"keypair", sym"eddsa-blake2b", bytes(seed32), bytes(pub32), nilValue()),
      Keypair,
    ).isNone
    # missing field
    check fromValue(record(sym"keypair", sym"eddsa-blake2b", bytes(seed32)), Keypair).isNone

  test "nested recognition, signed":
    let inner = mark(record(sym"greet", text"hello"))
    let v = record(
      sym"signed",
      inner,
      record(sym"signature", sym"eddsa-blake2b", bytes(sig64), bytes(pub32)),
    )
    let s = fromValue(v, Signed)
    check s.isSome
    check s.get.value == inner # passthrough keeps the mark
    check s.get.value.marked
    check s.get.signature.sig[0] == byte 4

  test "union: a directory holds files and directories":
    let leaf = toValue(File(contents: payload))
    let subdir = record(sym"directory", values.set(leaf), nilValue())
    let v = record(sym"directory", values.set(leaf, subdir), nilValue())
    let d = fromValue(v, Directory)
    check d.isSome
    check d.get.entries.len == 2
    var files, dirs = 0
    for e in d.get.entries:
      case e.kind
      of fsFile:
        inc files
      of fsDir:
        inc dirs
    check files == 1 and dirs == 1

  test "integers, the doc's (dec 15 -1)":
    let v = record(sym"dec", num"15", num"-1")
    let d = fromValue(v, Dec)
    check d.isSome
    check d.get.m == 15 and d.get.e == -1
    check toValue(d.get) == v
    # doesn't fit an int -> refused, not truncated
    check fromValue(record(sym"dec", num"99999999999999999999999", num"0"), Dec).isNone
    # DecimalString carries what int can't, losslessly
    let big = fromValue(record(sym"big", num"99999999999999999999999"), Big)
    check big.isSome
    check $big.get.n == "99999999999999999999999"
    check toValue(big.get) == record(sym"big", num"99999999999999999999999")

suite "epistemics and strictness":
  test "Option record slot is explicit nil, not elided arity":
    let f = File(contents: payload) # info: none
    let v = toValue(f)
    check v == record(sym"file", bytes(payload), nilValue()) # 3 slots
    check fromValue(v, File).get.info.isNone
    # a 2-slot file is a different shape and is refused
    check fromValue(record(sym"file", bytes(payload)), File).isNone

  test "Option dict key is silence, omitted entirely":
    let v = toValue(FileInfo(name: some "x")) # zip: none
    check v == dict(@[(sym"name", text"x")]) # no zip key at all
    let back = fromValue(v, FileInfo)
    check back.get.zip.isNone

  test "dict shapes are closed and required keys required":
    # unknown key refused
    check fromValue(dict(@[(sym"name", text"x"), (sym"extra", num"1")]), FileInfo).isNone
    # required key missing
    check fromValue(dict(@[(sym"content-type", sym"text")]), Pinned).isNone
    # blKey spells what a Nim identifier can't
    let p = fromValue(
      dict(@[(sym"algo", sym"sha256"), (sym"content-type", sym"text")]), Pinned
    )
    check p.isSome
    check p.get.contentType.get == Sym"text"

  test "enums are symbol vocabulary":
    check fromValue(dict(@[(sym"zip", sym"bogus")]), FileInfo).isNone
    check fromValue(dict(@[(sym"zip", text"gzip")]), FileInfo).isNone

  test "marks are refused in typed slots":
    # a marked record is an instruction, not a statement of this shape
    check fromValue(mark(record(sym"digest", sym"sha256", bytes(payload))), Digest).isNone
    # a marked scalar inside a slot likewise
    check fromValue(record(sym"digest", mark(sym"sha256"), bytes(payload)), Digest).isNone

  test "kind confusion is refused":
    check fromValue(record(sym"digest", text"sha256", bytes(payload)), Digest).isNone
      # text where symbol expected
    check fromValue(record(sym"file", list(num"1"), nilValue()), File).isNone
      # list where bytes expected
