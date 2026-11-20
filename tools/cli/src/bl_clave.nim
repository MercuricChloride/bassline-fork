## bl-clave, run as `bl clave`: keypairs, signing and verifying
##
## Built apart from bl so that bl carries no signing code. A keypair is
## a value, kept in a file; a signature covers a value's CE bytes, so
## checking one needs nothing but the signed value.

import std/[os, posix, sysrand, strutils, sugar]
import harness
import bl/lib/crypto/clave

proc defaultKey(): string =
  ## everything bl keeps locally lives under ~/.bl
  getHomeDir() / ".bl" / "key.blb"

proc writePrivate(path: string, data: openArray[byte], force: bool) =
  ## Writes `data` to `path` readable by its owner only, whole or not at
  ## all: through a fresh file beside it, then a rename (with `force`) or
  ## a link, which refuses an existing path.
  let dir = path.parentDir
  if dir.len > 0 and not dirExists(dir):
    try: createDir(dir)
    except OSError as e: fail "can't make " & dir & ": " & e.msg
    discard chmod(dir.cstring, Mode(S_IRWXU))
  if not force and fileExists(path):
    fail path & " exists (--force replaces it)"
  let tmp = path & ".new-" & $getpid()
  let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_EXCL,
                      Mode(S_IRUSR or S_IWUSR))
  if fd < 0:
    fail "can't write " & tmp & ": " & $strerror(errno)
  if not writeAll(fd, data) or fsync(fd) != 0:
    let err = errno
    discard posix.close(fd)
    discard unlink(tmp.cstring)
    fail "can't write " & tmp & ": " & $strerror(err)
  discard posix.close(fd)
  if force:
    try:
      moveFile(tmp, path) # rename(2), here in the same directory
    except OSError as e:
      discard unlink(tmp.cstring)
      fail "can't write " & path & ": " & e.msg
    return
  let placed = link(tmp.cstring, path.cstring)
  let err = errno
  discard unlink(tmp.cstring)
  if placed != 0:
    if err == EEXIST:
      fail path & " exists (--force replaces it)"
    fail "can't write " & path & ": " & $strerror(err)

proc loadKeypair(path: string): Keypair =
  let bytes =
    try: readFile(path)
    except IOError: fail "no key at " & path & " (bl clave keygen makes one)"
  try:
    Keypair.fromValue decodeOne(bytes.toOpenArrayByte(0, bytes.high), path)
  except ValueError as e:
    fail path & " doesn't hold a keypair: " & e.msg

proc keygen(t: Tool, a: Args) =
  if a.positional.len > 0:
    t.misuse "takes no arguments"
  let path = a.get("out", defaultKey())
  var seed: Seed
  if not urandom(seed):
    fail "the system has no randomness to give"
  let kp = keypairFromSeed(seed)
  writePrivate(path, kp.toValue.ce, a.has("force"))
  chatter "wrote " & path
  chatter "public " & hexString(kp.pubkey)

proc sign(t: Tool, a: Args) =
  if a.positional.len > 0:
    t.misuse "takes no arguments"
  let kp = loadKeypair(a.get("key", defaultKey()))
  lift((v: Value) => just kp.signed(v).toValue)

proc verify(t: Tool, a: Args) =
  if a.positional.len > 0:
    t.misuse "takes no arguments"
  let drop = a.has("drop")
  var held, dropped = 0
  proc verified(v: Value): Stream[Value] =
    var why = ""
    try:
      if Signed.fromValue(v).holds:
        inc held
        return just(v)
      why = "its signature does not hold"
    except ValueError as e:
      why = "not a signed value: " & e.msg
    if not drop:
      fail "value " & $(held + dropped + 1) & " on stdin: " & why
    inc dropped
    chatter "dropped value " & $(held + dropped) & " (" & $dropped &
      " so far): " & why
    empty Value
  lift verified
  if dropped > 0:
    chatter "held " & $held & ", dropped " & $dropped

let tools = [
  Tool(name: "clave keygen", summary: "make a keypair and keep it, owner-only",
       about: """
The seed comes from the system's randomness, and the pair is written as
the CE of (keypair eddsa-blake2b 0x<seed> 0x<public>). The file is the
secret: keep it, and don't send it as a value. The public key is said
on stderr.""",
       opts: @[Opt(long: "out", arg: "PATH",
                   help: "where to keep it (default ~/.bl/key.blb)"),
               Opt(long: "force", help: "replace a key already there")],
       run: keygen),
  Tool(name: "clave sign",
       summary: "each value on stdin to (signed VALUE (signature …))",
       about: """
The signature covers the value's CE bytes, and carries the public key,
so checking it needs only the signed value.""",
       opts: @[Opt(long: "key", arg: "PATH",
                   help: "the keypair (default ~/.bl/key.blb)")],
       run: sign),
  Tool(name: "clave verify",
       summary: "pass on the signed values whose signatures hold, as they are",
       about: """
Each value must be (signed VALUE (signature …)) and its signature must
hold over VALUE; it goes on whole, signature and all. Anything else is
fatal, with its reason, after the values before it. Whose key signed
is for whatever reads the output to judge.""",
       opts: @[Opt(long: "drop", help: "drop what doesn't hold instead, " &
                                       "saying so on stderr")],
       run: verify)]

proc usage(): string =
  result = "usage: bl clave COMMAND [ARGS…]\n\nkeypairs, signing and verifying\n\n"
  for t in tools:
    result.add "  " & t.name.split(' ')[1].pad(8) & "  " & t.summary &
               "\n"
  result.add "\n`bl clave COMMAND --help` says more about each.\n"

proc main() =
  let argv = commandLineParams()
  if argv.len == 0:
    chatter "bl clave: name a command"
    toStderr "\n" & usage()
    quit 2
  if argv[0] in ["-h", "--help"]:
    say usage()
    return
  for t in tools:
    if t.name == "clave " & argv[0]:
      t.start(argv[1 .. ^1])
      return
  chatter "bl clave: no command " & argv[0]
  toStderr "\n" & usage()
  quit 2

when isMainModule:
  main()
