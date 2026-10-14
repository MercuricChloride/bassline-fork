## A line to a jam, for the jam's own clients: the speaker on it, and the
## reader's own space of what the jam has told it

import std/[options, os, posix, times, sugar]
import harness
import bl/[core, queries]
import bl/lib/[server, jam]
import bl/lib/crypto/clave

const JamPlace* = "127.0.0.1:8456"
  ## where the jam's clients look by default
const JamListen* = "0.0.0.0:8456"
  ## where `bl jam serve` listens by default: every interface, so the
  ## clients here find it at JamPlace and others reach it on the network

type
  Client* = ref object
    conn: Conn
    speaker*: Speaker
    local*: BVar[Value, Ranked[Value]]  ## what the jam has told it
    told: BSet                          ## every record told, so each is heard once
    asked*: seq[Value]                  ## the questions asked on it
    onHeard*: (Heard) -> void           ## told of each answer as it comes
    closed*: bool                       ## whether the jam has gone
    jam*: Option[Value]                 ## which jam it is, once it has said
    elsewhere*: Option[Value]           ## another jam found at its place since

proc defaultKey*(): string =
  getHomeDir() / ".bl" / "key.blb"

proc loadKeypair*(path: string): Keypair =
  ## the keypair kept at `path`, as `bl clave keygen` keeps one
  let bytes =
    try: readFile(path)
    except IOError: fail "no key at " & path & " (bl clave keygen makes one)"
  try:
    Keypair.fromValue decodeOne(bytes.toOpenArrayByte(0, bytes.high), path)
  except ValueError as e:
    fail path & " doesn't hold a keypair: " & e.msg

proc speakerFrom*(t: Tool, a: Args, signs = false): Speaker =
  ## who speaks, from --as, --key, --sign and --no-sign: a name, and a key
  ## if signing. Where `signs`, the person's own key signs when it is
  ## there, unless --no-sign
  let name = a.get("as", getEnv("JAM_NAME", configured("as", getEnv("USER", "someone"))))
  result.name = sym(name)
  if a.has("key"): result.key = some loadKeypair(a.get("key"))
  elif a.has("sign"): result.key = some loadKeypair(defaultKey())
  elif signs and not a.has("no-sign") and fileExists(defaultKey()):
    result.key = some loadKeypair(defaultKey())

proc placeFrom*(t: Tool, a: Args): Place =
  let spelled = a.get("at", getEnv("JAM_AT", configured("at", JamPlace)))
  result = try: parsePlace(spelled) except ValueError as e: t.misuse e.msg
  if result.kind != tcpPlace: t.misuse "a jam is reached over tcp"

let speakingOpts* = @[
  Opt(long: "at", arg: "PLACE", help: "the jam (default $JAM_AT, else the config's at, else " &
                                     JamPlace & ")"),
  Opt(long: "as", arg: "NAME", help: "the name to go by (default $JAM_NAME, else the config's as, " &
                                     "else $USER)"),
  Opt(long: "key", arg: "PATH", help: "sign everything with this keypair"),
  Opt(long: "sign", help: "sign everything with ~/.bl/key.blb"),
  Opt(long: "no-sign", help: "sign nothing (bl jam signs with ~/.bl/key.blb " &
                             "when it is there)")]

proc called*(jam: Option[Value]): string =
  ## the name a jam goes by, from its answer to (jam), or nothing
  if jam.isSome: nameOf(jam.get) else: ""

proc ask*(c: Client, q: Value)
proc turn*(ms: int)

proc dial*(place: Place, speaker: Speaker, was: Client = nil): Client =
  ## a line to the jam at `place`, keeping what `was`, a line gone, was
  ## told, so only what is new to it is heard. It asks (jam) before
  ## anything else, so what it is told first is which jam is there; for
  ## a line dialled again that is the jam `was` was told by, or it hangs
  ## up before saying anything, keeping in `was` which jam it found.
  ## Raises if it can't be reached
  let c =
    if was == nil: Client(speaker: speaker, local: spaceVar[Value, Ranked[Value]](),
                          told: newBSet())
    else: Client(speaker: speaker, local: was.local, told: was.told,
                 onHeard: was.onHeard, jam: was.jam)
  c.conn = waitFor connect(place.host, place.port)
  var first = true
  proc arrived(v: Value): bool =
    if first:
      first = false
      let h = heard(v)
      if h.isSome and h.get.q == JamQ:
        if c.jam.isSome and h.get.said != c.jam.get:
          c.elsewhere = some h.get.said
          c.conn.close()
          return false
        c.jam = some h.get.said
    if v in c.told: return true
    c.told.incl v
    let h = c.local.keep(v)
    if h.isSome and c.onHeard != nil: c.onHeard(h.get)
    true
  let pumping = c.conn.pump(arrived)
  pumping.addCallback(() => (block: c.closed = true))
  c.ask JamQ
  if c.jam.isSome:
    # a jam that doesn't say which it is is taken as the one it was
    let until = epochTime() + 2
    while first and not c.closed and epochTime() < until: turn(10)
    if c.elsewhere.isSome:
      was.elsewhere = c.elsewhere
      let (now, then) = (called(c.elsewhere), called(c.jam))
      raise newException(IOError, "the jam at " & $place & " is " &
        (if now.len > 0: now else: "another") & " now, not " &
        (if then.len > 0: then else: "the one this line was on"))
  c

proc send(c: Client, v: Value): bool =
  not c.closed and c.conn.write(v)

proc ask*(c: Client, q: Value) =
  ## asks the jam `q`, once
  if q notin c.asked and c.send(c.speaker.ask(q)):
    c.asked.add q

proc put*(c: Client, q, a: Value): Value =
  ## puts `a` as an answer to `q`, answering the answer as the jam will
  ## keep it, to know it when it is told back
  let v = c.speaker.put(q, a)
  discard c.send(v)
  if c.speaker.key.isSome: v else: a

proc hello*(c: Client): Value {.discardable.} =
  ## the questions everyone asks, who is here, who has gone, which rooms
  ## there are and what is for them, and then that the speaker is here,
  ## answering that as the jam will keep it: once the jam tells it back,
  ## it has told what it had for everything asked before
  for q in [HereQ, GoneQ, RoomsQ, initRec(@[ForQ, c.speaker.name])]:
    c.ask q
  c.put(HereQ, c.speaker.here)

proc bye*(c: Client) =
  ## that the speaker has stopped listening, sent before the line closes
  discard c.put(GoneQ, c.speaker.gone)
  try: discard waitFor c.conn.flush().withTimeout(1000)
  except CatchableError: discard
  c.conn.close()

proc turn*(ms: int) =
  ## lets the line hear what has come, waiting up to `ms`
  if hasPendingOperations(): poll(ms)
  else: sleep(ms)

proc readable*(fd: cint): bool =
  ## whether `fd` has bytes to read now
  var fds: TFdSet
  FD_ZERO(fds)
  FD_SET(fd, fds)
  var tv = Timeval(tv_sec: posix.Time(0), tv_usec: Suseconds(0))
  select(fd + 1, addr fds, nil, nil, addr tv) > 0
