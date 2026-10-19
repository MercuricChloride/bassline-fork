## What every bl tool shares: the pipe rule, options and usage, places,
## value arguments, finding and running other tools, and lifting a
## search into a filter. The conventions are the bl toolkit's, in the
## bassline-zoo skill's cli.md.

import std/[algorithm, nativesockets, options, os, osproc, parseopt, posix,
            sequtils, sets, strutils, tables, unicode, sugar]
import std/streams except Stream
from std/net import nil
import bl/core
import bl/queries
from bl/parties/parties import PartyPort
from bl/parties/place import placeOf
export options, core, stream, Port

const
  ReadChunk* = 64 * 1024
    ## what one read(2) asks for. It hands back whatever has arrived, so a
    ## live pipe is never held up waiting for the chunk to fill.
  LocalMaxValueBytes* = high(int) div 2
    ## the decoder's cap for local input, a pipe or a file. blnim's
    ## default (MaxValueBytes) is for strangers on a socket; what comes
    ## in here was handed over on purpose, so the cap is only what memory
    ## allows.

# A closed downstream pipe shows up as EPIPE on the write that meets it,
# instead of a signal that kills the process partway through a value.
discard signal(SIGPIPE, SIG_IGN)

# ================ stderr ================

proc toStderr*(s: string) =
  ## best effort: if stderr is gone there is nowhere left to say so
  var done = 0
  while done < s.len:
    let n = posix.write(2, addr s[done], s.len - done)
    if n < 0:
      if errno == EINTR: continue
      return
    done += n

proc chatter*(line: string) =
  ## one event on stderr, as one line starting `-- `
  toStderr("-- " & line & "\n")

proc fail*(reason: string) {.noreturn.} =
  ## the reason on stderr, exit 1
  chatter reason
  quit 1

# ================ stdout ================

proc waitReady(fd: cint, writing: bool) =
  ## Blocks until `fd` can be read or written. A pipe or terminal that
  ## some other program left non-blocking answers EAGAIN instead of
  ## waiting, and that is no reason to stop.
  var ready: TFdSet
  FD_ZERO(ready)
  FD_SET(fd, ready)
  if writing: discard select(fd + 1, nil, addr ready, nil, nil)
  else: discard select(fd + 1, addr ready, nil, nil, nil)

proc writeAll*(fd: cint, data: openArray[byte]): bool =
  ## All of `data` to `fd`, through partial writes and interrupts.
  ## False when whoever reads `fd` has gone; any other failure is fatal.
  var done = 0
  while done < data.len:
    let n = posix.write(fd, addr data[done], data.len - done)
    if n < 0:
      let err = errno
      if err == EINTR: continue
      if err == EAGAIN or err == EWOULDBLOCK:
        waitReady(fd, writing = true)
        continue
      if err == EPIPE or err == ECONNRESET: return false
      fail "write failed: " & $strerror(err)
    done += n
  true

proc emit*(ce: openArray[byte]) =
  ## CE bytes to stdout, all of them before returning, so every value is
  ## flushed as it is written. A closed downstream ends the tool quietly.
  if not writeAll(1, ce):
    quit 0

proc emit*(v: Value) =
  emit v.ce

proc say*(text: string) =
  ## text to stdout, for help and for a tool whose job is text
  if text.len > 0:
    emit text.toOpenArrayByte(0, text.high)

# ================ stdin ================

type Source* = object
  fd*: cint
  name*: string ## what chatter calls it

proc stdinSource*(): Source =
  Source(fd: 0, name: "stdin")

proc openSource*(path: string): Source =
  ## a file to read, `-` meaning stdin. One that won't open is fatal.
  if path == "-":
    return stdinSource()
  let fd = posix.open(path.cstring, O_RDONLY)
  if fd < 0:
    fail "can't open " & path & ": " & $strerror(errno)
  Source(fd: fd, name: path)

proc close*(s: Source) =
  if s.fd > 2:
    discard posix.close(s.fd)

proc readSome*(s: Source, buf: pointer, len: int): int =
  ## raw read(2): whatever has arrived, as soon as anything has; 0 at
  ## the end. stdio's fread would wait for a whole buffer, stalling a
  ## live pipeline until its input closes.
  while true:
    result = posix.read(s.fd, buf, len)
    if result >= 0:
      return
    let err = errno
    if err == EAGAIN or err == EWOULDBLOCK:
      waitReady(s.fd, writing = false)
    elif err != EINTR:
      fail "can't read " & s.name & ": " & $strerror(err)

proc eachView*(s: Source, onValue: (ValueView) -> void, onBatch: () -> void = nil) =
  ## Hands on every value on `s` in order, each as soon as its last byte
  ## has arrived; `onBatch` runs after the values from each read. A view
  ## borrows the decoder's buffer and lives only for its call. Input
  ## that is not CE, or that ends partway through a value, is fatal,
  ## after the values before it have gone on.
  var
    d = newDecoder(maxValueBytes = LocalMaxValueBytes)
    buf = newSeq[byte](ReadChunk)
    handing = false # a CodecError from onValue is its own, not the input's
  while true:
    let n = s.readSome(addr buf[0], buf.len)
    if n == 0:
      break
    d.buf.add buf.toOpenArray(0, n - 1)
    var bad: ref CodecError
    try:
      # drained whole every turn: the decoder can't be left partway
      for v in d.checked:
        handing = true
        onValue(v)
        handing = false
    except CodecError as e:
      if handing: raise
      bad = e
    if onBatch != nil:
      onBatch()
    if bad != nil:
      fail s.name & " is not CE: " & bad.msg
    d.compact()
  if d.pending:
    fail s.name & " ends partway through a value (" & $d.buf.len &
      " bytes of it)"

proc eachValue*(s: Source, onValue: (Value) -> void, onBatch: () -> void = nil) =
  s.eachView((v: ValueView) => onValue(v.toValue), onBatch)

proc decodeOne*(bytes: openArray[byte], name: string): Value =
  ## exactly one CE value, or a ValueError saying why not
  var
    d = newDecoder(newBuffer(bytes), maxValueBytes = LocalMaxValueBytes)
    found: seq[Value]
  try:
    for v in d.checked:
      found.add v.toValue
  except CodecError as e:
    raise newException(ValueError, name & " is not CE: " & e.msg)
  if d.pending:
    raise newException(ValueError, name & " ends partway through a value")
  if found.len != 1:
    raise newException(ValueError,
                       name & " holds " & $found.len & " values, not one")
  found[0]

# ================ searches as filters ================

proc lift*(search: Search[Value, Value], take = -1, src = stdinSource()) =
  ## A filter over `src`: asks `search` about each value as it arrives
  ## and writes every answer its stream gives, each as it is pulled.
  ## Answers are pulled only as fast as stdout takes them. With `take`
  ## at 0 or more, stops after that many answers.
  if take == 0:
    return
  var taken = 0
  proc each(v: Value) =
    for answer in search[v]:
      emit answer
      inc taken
      if taken == take:
        quit 0
  src.eachValue each

proc lift*(ask: (Value) -> Stream[Value], take = -1, src = stdinSource()) =
  ## the same, for a search made from `ask`
  lift(newSearch[Value, Value](ask), take, src)

# ================ options and usage ================

type
  Opt* = object
    long*: string  ## `--long`
    short*: char   ## `-s`, or '\0' for none
    arg*: string   ## what its value stands for ("N", "PATH"); "" for a flag
    help*: string

  Args* = object
    positional*: seq[string]
    command*: seq[string] ## after a bare `--`, for a tool that runs one
    given: Table[string, string]
    every: Table[string, seq[string]] ## each value an option was given, in order

  Tool* = object
    name*: string    ## as typed after `bl`
    args*: string    ## the positionals, for the synopsis
    summary*: string ## one line
    about*: string   ## more, after the summary
    opts*: seq[Opt]
    command*: bool   ## whether `-- CMD ARGS…` is this tool's own; otherwise
                     ## what follows `--` is more positionals
    run*: (Tool, Args) -> void
    raw*: (seq[string]) -> void
      ## when set, takes the arguments as they come, in place of `run`

func columns*(s: string): int =
  ## how wide `s` prints, counting characters, not bytes
  s.runeLen

func pad*(s: string, width: int): string =
  ## `s` and spaces to fill `width` columns, counting characters, not bytes
  s & spaces(max(0, width - s.runeLen))

func spell(o: Opt): string =
  result = if o.short != '\0': "-" & o.short else: "--" & o.long
  if o.arg.len > 0:
    result.add " " & o.arg

func synopsis*(t: Tool): string =
  result = "bl " & t.name
  for o in t.opts:
    result.add " [" & o.spell & "]"
  if t.args.len > 0:
    result.add " " & t.args

func usage*(t: Tool): string =
  result = "usage: " & t.synopsis & "\n\n" & t.summary & "\n"
  if t.about.len > 0:
    result.add "\n" & t.about.strip(leading = false) & "\n"
  result.add "\noptions:\n"
  for o in t.opts:
    var left = (if o.short != '\0': "-" & o.short & ", " else: "    ") &
               "--" & o.long
    if o.arg.len > 0:
      left.add " " & o.arg
    result.add "  " & left.pad(22) & " " & o.help & "\n"
  result.add "  " & "-h, --help".pad(22) & " this help\n"

proc misuse*(t: Tool, reason: string) {.noreturn.} =
  ## a wrong invocation: one line of reason, then the usage, on stderr;
  ## exit 2
  chatter "bl " & t.name & ": " & reason
  toStderr "\n" & t.usage
  quit 2

proc parse*(t: Tool, argv: seq[string]): Args =
  ## `argv` read against the tool's options. `-h` or `--help` prints the
  ## usage and exits 0; an option the tool doesn't declare, a flag given
  ## a value, or an option missing its value is a misuse. Long options
  ## take `--name value`, `--name=value` or `--name:value`; short ones
  ## `-n value` or `-nvalue`.
  let cut = argv.find("--")
  let head = if cut >= 0: argv[0 ..< cut] else: argv
  # parseopt footgun: initOptParser on an empty seq reads the process's
  # own command line instead, feeding the command's name back in
  if head.len > 0:
    # parseopt footgun: `--name value` only works while the no-value sets
    # are non-empty, and a flag missing from them takes the next argument
    # as its value. So the sets come from the declarations, and always
    # hold help.
    var
      shortFlags = {'h'}
      longFlags = @["help"]
    for o in t.opts:
      if o.arg.len == 0:
        longFlags.add o.long
        if o.short != '\0':
          shortFlags.incl o.short
    var p = initOptParser(head, shortNoVal = shortFlags,
                          longNoVal = longFlags, mode = LaxMode)
    while true:
      p.next()
      case p.kind
      of cmdEnd:
        break
      of cmdArgument:
        result.positional.add p.key
      of cmdShortOption, cmdLongOption:
        if p.kind == cmdShortOption and p.key.len == 0:
          # a lone `-` is an argument, conventionally stdin; parseopt
          # reads it as a short option with no name
          result.positional.add "-"
          continue
        if p.key in ["h", "help"]:
          say t.usage
          quit 0
        let dash = if p.kind == cmdLongOption: "--" else: "-"
        var found = -1
        for i, o in t.opts:
          if (p.kind == cmdLongOption and o.long == p.key) or
             (p.kind == cmdShortOption and o.short != '\0' and
              p.key == $o.short):
            found = i
        if found < 0:
          t.misuse "unknown option " & dash & p.key
        let o = t.opts[found]
        if o.arg.len == 0 and p.val.len > 0:
          t.misuse dash & p.key & " takes no value"
        if o.arg.len > 0 and p.val.len == 0:
          t.misuse dash & p.key & " needs " & o.arg
        result.given[o.long] = p.val
        result.every.mgetOrPut(o.long, @[]).add p.val
  if cut >= 0:
    if t.command:
      result.command = argv[cut + 1 .. ^1]
      if result.command.len == 0:
        t.misuse "-- wants a command after it"
    else:
      result.positional.add argv[cut + 1 .. ^1]

proc has*(a: Args, long: string): bool =
  long in a.given

proc get*(a: Args, long: string, default = ""): string =
  a.given.getOrDefault(long, default)

proc every*(a: Args, long: string): seq[string] =
  ## every value an option was given, for one that may be given again
  a.every.getOrDefault(long)

proc intOpt*(t: Tool, a: Args, long: string, default: int, lo = 0): int =
  ## a whole-number option of at least `lo`, or `default` when not given
  if not a.has(long):
    return default
  let s = a.get(long)
  try:
    result = parseInt(s)
  except ValueError:
    t.misuse "--" & long & " wants a whole number, got " & s
  if result < lo:
    t.misuse "--" & long & " is at least " & $lo & ", got " & s

proc toolDefaults(t: Tool): seq[string]

proc start*(t: Tool, argv: seq[string]) =
  ## runs the tool on `argv`, after the options the config gives it by
  ## default, so its command line has the last word. `--no-defaults`,
  ## before any `--`, leaves the config's out
  if t.raw != nil:
    t.raw(argv)
    return
  let cut = argv.find("--")
  let plain = (if cut >= 0: argv[0 ..< cut] else: argv).find("--no-defaults")
  var given = argv
  if plain >= 0: given.delete(plain)
  t.run(t, t.parse((if plain >= 0: @[] else: t.toolDefaults) & given))

# ================ places ================

type
  PlaceKind* = enum
    tcpPlace, sshPlace

  Place* = object
    ## Where bytes go to or come from: for people and the edge, never a
    ## value.
    case kind*: PlaceKind
    of tcpPlace:
      host*: string
      port*: Port
    of sshPlace:
      sshHost*: string ## host or user@host, ssh's business
      remote*: string  ## the TCP place `bl reach` is given on the far side

const DefaultPlace* = "127.0.0.1:8455"
  ## where `bl send` speaks, given no place
const DefaultListen* = "0.0.0.0:8455"
  ## where `bl serve` listens, given no place: every interface, so `bl
  ## send` meets it here at DefaultPlace and others reach it on the network

proc `$`*(p: Place): string =
  case p.kind
  of tcpPlace: (if ':' in p.host: "[" & p.host & "]" else: p.host) & ":" &
               $p.port
  of sshPlace: "ssh://" & p.sshHost & "/" & p.remote

proc parsePort(s: string, allowZero: bool): Port =
  ## Port(n) wraps silently past its range, so the range is checked here
  let lo = if allowZero: 0 else: 1
  var n = -1
  if s.len > 0 and s.allCharsInSet(Digits):
    try: n = parseInt(s)
    except ValueError: discard # too many digits for an int
  if n < lo or n > int(high(uint16)):
    raise newException(ValueError, "a port is a number from " & $lo &
                       " to " & $high(uint16) & ", not " & s)
  Port(n)

proc parseTcp(s: string, allowZero: bool): Place =
  ## the TCP spellings, or a ValueError saying why `s` isn't one. No TCP
  ## spelling has a slash outside `tcp://`, so one that does is a path,
  ## refused by name rather than read as a host.
  template bad(why: string) =
    raise newException(ValueError, why)
  let tcp = s.startsWith("tcp://")
  if s.startsWith("unix:") or ('/' in s and not tcp):
    bad "unix sockets aren't places, only TCP"
  let hostPort = if tcp: s[6 .. ^1] else: s
  var
    host = "127.0.0.1"
    portText = hostPort
  let colon = hostPort.rfind(':')
  if colon >= 0:
    var h = hostPort[0 ..< colon]
    portText = hostPort[colon + 1 .. ^1]
    if h.len >= 2 and h[0] == '[' and h[^1] == ']':
      h = h[1 .. ^2]
    elif ':' in h:
      bad "an IPv6 host goes in brackets, as [" & h & "]:port"
    if h.len > 0:
      host = h
  elif tcp:
    bad "tcp:// wants host:port"
  Place(kind: tcpPlace, host: host, port: parsePort(portText, allowZero))

# ================ config ================

const ProbeMs = 500
  ## how long a name with several places waits on each for a connection

proc configFile*(): string =
  ## where this person's own answers are kept: the textual syntax, a
  ## (Q A) record for each answer, a question answered as often as it has
  ## answers
  getHomeDir() / ".bl" / "config.bl"

proc isName*(s: string): bool =
  ## whether `s` spells a name rather than a place: a letter, then
  ## letters, digits, '.', '_' and '-'. No place is spelled so, a TCP
  ## place having a port and an ssh place its scheme
  s.len > 0 and s[0] in Letters and s.allCharsInSet(Letters + Digits + {'.', '_', '-'})

proc configValues*(): seq[Value] =
  ## every value the config holds, in order; nothing when there is no file
  let path = configFile()
  if not fileExists(path):
    return
  try: readDocument(readFile(path))
  except IOError as e: fail "can't read " & path & ": " & e.msg
  except ValueError as e: fail path & " doesn't read: " & e.msg

proc answerOf*(v: Value): Option[(Value, Value)] =
  ## a (Q A) record, read: its question and its answer
  if v.isKind(bRec, unmarked) and v.items.len == 2:
    return some (v.items[0], v.items[1])

proc configured*(q: Value): seq[Value] =
  ## the config's answers to `q`, in the order kept
  for v in configValues():
    let qa = answerOf(v)
    if qa.isSome and qa.get[0] == q:
      result.add qa.get[1]

proc configured*(q, default: string): string =
  ## the config's first answer to the question `q`, a symbol, that is a
  ## symbol or text, else `default`
  for answer in configured(sym(q)):
    if answer.isKind({bSym, bText}):
      return answer.text
  default

proc keepConfig*(values: seq[Value]) =
  ## configFile written whole: a fresh file beside it, then a rename
  let path = configFile()
  try:
    createDir(path.parentDir)
    let fresh = path & ".new-" & $getpid()
    var text = ""
    for v in values:
      text.add pretty(v) & "\n"
    writeFile(fresh, text)
    moveFile(fresh, path)
  except OSError, IOError:
    fail "can't write " & path & ": " & getCurrentExceptionMsg()

proc configure*(q: Value, answers: seq[Value], adding = false) =
  ## `answers` become the config's answers to `q`, in place of those it
  ## had unless `adding`, where the first of those stood
  let kept = configValues()
  var next: seq[Value]
  var put = false
  for v in kept:
    let qa = answerOf(v)
    if qa.isNone or qa.get[0] != q or adding:
      next.add v
    elif not put:
      for answer in answers: next.add initRec(@[q, answer])
      put = true
  if not put:
    for answer in answers: next.add initRec(@[q, answer])
  keepConfig next

proc forget*(q: Value, answer = none(Value)): bool {.discardable.} =
  ## takes away the config's answers to `q`, or only `answer`, answering
  ## whether there were any
  let kept = configValues()
  var next: seq[Value]
  for v in kept:
    let qa = answerOf(v)
    if qa.isSome and qa.get[0] == q and (answer.isNone or qa.get[1] == answer.get):
      result = true
    else:
      next.add v
  if result: keepConfig next

proc defaultsQ*(tool: string): Value =
  ## the question a tool's defaults answer, (defaults WORD …), the words of
  ## its name: (defaults jam serve)
  initRec(@[sym"defaults"] & strutils.splitWhitespace(tool).mapIt(sym(it)))

proc toolDefaults(t: Tool): seq[string] =
  ## the options the config gives `t` ahead of its command line: a symbol
  ## for a flag, (NAME VALUE) for an option and its value, `~` in a value
  ## this person's home
  for answer in configured(defaultsQ(t.name)):
    var name: string
    var value: Option[string]
    if answer.isKind(bSym, unmarked):
      name = answer.text
    elif answer.isKind(bRec, unmarked) and answer.items.len == 2 and
         answer.head.isKind(bSym, unmarked):
      name = answer.head.text
      let v = answer.items[1]
      value = some(if v.isKind({bSym, bText}): v.text.expandTilde else: pretty(v))
    else:
      fail "the config's " & pretty(defaultsQ(t.name)) & " has " & pretty(answer) &
        ", which is neither a flag nor (OPTION VALUE)"
    let declared = t.opts.filterIt(it.long == name)
    if declared.len == 0:
      fail "the config gives " & t.name & " --" & name & ", which it doesn't take " &
        "(bl config defaults " & t.name & " sets what it gives)"
    if (declared[0].arg.len > 0) != value.isSome:
      fail "the config gives " & t.name & " --" & name &
        (if value.isSome: " with a value, and it is a flag" else: " without " & declared[0].arg & ", which it needs")
    result.add "--" & name
    if value.isSome: result.add value.get

proc placeQ*(name: string): Value =
  ## the question a name answers: (place NAME)
  initRec(@[sym"place", sym(name)])

proc placesNamed*(name: string): seq[string] =
  ## the places `name` names, in the order they were given
  for answer in configured(placeQ(name)):
    if answer.isKind({bSym, bText}):
      result.add answer.text

proc takes(p: Place, ms: int): bool =
  ## whether something at the TCP place `p` takes a connection within `ms`
  let s = net.newSocket(buffered = false)
  defer: net.close(s)
  try:
    net.connect(s, p.host, p.port, ms)
    true
  except CatchableError:
    false

proc parsePlace*(s: string, allowZero = false): Place

proc reached(name: string, places: seq[string]): Place =
  ## the place a name names: its one place, or, of several, the first
  ## that takes a connection, else the first
  var ps: seq[Place]
  for spelled in places:
    if isName(spelled):
      raise newException(ValueError, name & " names another name, " & spelled &
                         ", in " & configFile())
    ps.add parsePlace(spelled)
  if ps.len > 1:
    for p in ps:
      if p.kind == tcpPlace and p.takes(ProbeMs):
        return p
  ps[0]

proc parsePlace*(s: string, allowZero = false): Place =
  ## `tcp://host:port`, `host:port`, `:port` or a bare port: TCP, the host
  ## 127.0.0.1 unless given (an IPv6 host goes in brackets).
  ## `ssh://host/PLACE`: `bl reach PLACE` run on the far side, PLACE a TCP
  ## place as the far side reads it; `ssh://host` alone reaches the far
  ## side's DefaultPlace. A name (`bl name` gives one) is the place it
  ## names, the first of several that takes a connection, and a name
  ## nothing names is the party at the place of that name. Port 0
  ## (whatever is free) only with `allowZero`, and never on the far side.
  ## A spelling that is none of these, a unix socket path among them,
  ## raises ValueError with the reason.
  template bad(why: string) =
    raise newException(ValueError, why)
  if s.len == 0:
    bad "a place can't be empty"
  if isName(s):
    let places = placesNamed(s)
    if places.len == 0:  # the party at the place of the name
      return Place(kind: tcpPlace, host: net.`$`(placeOf(sym(s))), port: PartyPort)
    return reached(s, places)
  if not s.startsWith("ssh://"):
    try: return parseTcp(s, allowZero)
    except ValueError as e: bad "not a place: " & s & " (" & e.msg & ")"
  let rest = s[6 .. ^1]
  let slash = rest.find('/')
  let host = if slash < 0: rest else: rest[0 ..< slash]
  if host.len == 0 or slash == rest.high:
    bad "ssh:// wants ssh://host or ssh://host/PLACE, got " & s
  if host[0] == '-':
    bad "an ssh host can't start with -, got " & s
  let far = if slash < 0: DefaultPlace else: rest[slash + 1 .. ^1]
  try:
    Place(kind: sshPlace, sshHost: host,
          remote: $parseTcp(far, allowZero = false))
  except ValueError as e:
    bad "not a place: " & s & " (on the far side, " & e.msg & ")"

# ================ value arguments ================

proc valueArg*(arg: string): Value =
  ## An argument that stands for a value, read by recognition: the file
  ## it names if there is one, else the argument itself. A file is CE if
  ## it decodes to one value, else the textual syntax. An argument typed
  ## inline is the textual syntax first, and CE only if the text refuses:
  ## CE rarely survives being a shell argument, while plain spellings
  ## often decode as CE by accident (`10` is the CE of the text "0").
  ## Raises ValueError with the reason.
  template text(src: string): Value =
    try:
      readValue(src)
    except ReadError as e:
      raise newException(ValueError, arg & " is neither one value in the " &
                         "textual syntax nor CE: " & e.msg)
  if fileExists(arg):
    var src: string
    try: src = readFile(arg)
    except IOError as e: raise newException(ValueError, e.msg)
    try: return decodeOne(src.toOpenArrayByte(0, src.high), arg)
    except ValueError: return text(src)
  try:
    return readValue(arg)
  except ReadError:
    try: return decodeOne(arg.toOpenArrayByte(0, arg.high), arg)
    except ValueError: return text(arg)

# ================ other tools ================

proc isExecutable(path: string): bool =
  fileExists(path) and access(path.cstring, X_OK) == 0

proc lookPath*(name: string): string =
  ## the first executable `name` in a PATH directory, as a shell finds
  ## it, or "". The stdlib's findExe takes any file, executable or not.
  for dir in getEnv("PATH").split(PathSep):
    if dir.len > 0 and isExecutable(dir / name):
      return dir / name

iterator toolDirs(): string =
  ## where bl looks for bl-NAME: beside itself first, so the tools built
  ## with it go together however bl was reached, then PATH
  yield getAppDir()
  for dir in getEnv("PATH").split(PathSep):
    if dir.len > 0:
      yield dir

proc lookTool*(name: string): string =
  ## the first executable `name` where bl looks for its tools, or ""
  for dir in toolDirs():
    if isExecutable(dir / name):
      return dir / name

proc tools*(prefix: string): seq[tuple[name, path: string]] =
  ## every executable named `prefix` and more where bl looks for its
  ## tools, the first of each name only, sorted by the name minus `prefix`
  var seen: HashSet[string]
  for dir in toolDirs():
    if not dirExists(dir):
      continue
    for kind, path in walkDir(dir):
      let base = path.extractFilename
      if kind in {pcFile, pcLinkToFile} and base.len > prefix.len and
          base.startsWith(prefix) and base notin seen and isExecutable(path):
        seen.incl base
        result.add (base[prefix.len .. ^1], path)
  result.sort

proc firstHelpLine*(exe: string): string =
  ## what `EXE --help` says first, given a moment to say it
  try:
    let p = startProcess(exe, args = ["--help"], options = {})
    defer: p.close()
    p.inputStream.close()
    if p.waitForExit(timeout = 2000) == -1 and p.running:
      p.kill()
      return "(said nothing to --help)"
    for line in p.outputStream.lines:
      if line.strip.len > 0 and not line.startsWith("usage:"):
        return line.strip
  except CatchableError:
    discard
  "(said nothing to --help)"

func lined*(rows: openArray[(string, string)], indent = ""): string =
  ## a name and a line of help each, the help lined up
  var width = 0
  for r in rows:
    width = max(width, r[0].columns)
  for (name, help) in rows:
    result.add indent & name.pad(width) & "  " & help & "\n"

proc sayRows*(rows: openArray[(string, string)]) =
  say lined(rows)

proc execTool*(argv: seq[string]) {.noreturn.} =
  ## Becomes `argv[0]`, so stdio, exit status and signals carry through.
  ## SIGPIPE goes back to its default first: ignoring it was this
  ## process's choice, and an ignored signal survives exec.
  discard signal(SIGPIPE, SIG_DFL)
  let cargs = allocCStringArray(argv)
  discard execv(argv[0].cstring, cargs)
  let err = errno
  discard signal(SIGPIPE, SIG_IGN)
  fail "can't run " & argv[0] & ": " & $strerror(err)

proc spawn*(argv: seq[string], stdinFd: cint = -1, stdoutFd: cint = -1,
            closing: openArray[cint] = []): Pid =
  ## Starts `argv` as a child with `stdinFd` and `stdoutFd` as its stdin
  ## and stdout (-1 keeps ours), first closing `closing` in it.
  let cargs = allocCStringArray(argv)
  result = fork()
  if result < 0:
    fail "can't start " & argv[0] & ": " & $strerror(errno)
  if result == 0:
    if stdinFd >= 0: discard dup2(stdinFd, 0)
    if stdoutFd >= 0: discard dup2(stdoutFd, 1)
    for fd in closing:
      discard posix.close(fd)
    discard signal(SIGPIPE, SIG_DFL)
    discard execv(argv[0].cstring, cargs)
    exitnow(127)
  deallocCStringArray(cargs)

proc waitExit*(pid: Pid): int =
  ## the child's exit status, or 128 plus the signal that ended it
  var status: cint
  while waitpid(pid, status, 0) < 0:
    if errno != EINTR:
      return -1
  if WIFEXITED(status): WEXITSTATUS(status) else: 128 + WTERMSIG(status)

proc sshArgv*(p: Place, reachArgs: seq[string]): seq[string] =
  ## `ssh HOST bl reach REACHARGS… PLACE`, with what goes to the far side
  ## quoted for the shell there. Sink-only gets `ssh -n`, so ssh leaves
  ## our stdin alone.
  let ssh = lookPath("ssh")
  if ssh.len == 0:
    fail "no ssh on PATH, for " & $p
  result = @[ssh]
  if "--sink" in reachArgs:
    result.add "-n"
  result.add [p.sshHost, "bl", "reach"]
  for a in reachArgs:
    result.add quoteShell(a)
  result.add quoteShell(p.remote)
