## References read into one shape. RFC 3986 URIs, and the schemes that
## bend its syntax (did, urn, mailto, scp-style git paths, bare addresses),
## become a dict with up to five slots, each present only when said:
##
##   scheme   the reading that resolves it
##   who      the party responsible for the name, {name: … user: … port: …}
##   where    the path within that party's names, a list of text
##   how      qualifiers, a list of (key value) pairs in the order given
##   which    the fragment, a part of the referent chosen after resolution
##
## Percent escapes are decoded. Delimiters and escapes are the syntax's
## framing and do not survive.

import std/[options, sequtils, strutils, sugar]
import petit_parser
import ../core/shared/shared
import ./bassline_text

type
  Authority = (Option[string], string, Option[string])
  Generic = (Option[string], (Option[Authority], seq[string]), Option[seq[(string, Option[string])]],
             Option[string])   ## scheme, hierarchy, query, fragment, as read
  Ref = object
    scheme, user, name, port, which: Option[string]
    where: seq[string]
    how: Option[seq[(string, Option[string])]]

const
  Unreserved = Letters + Digits + {'-', '.', '_', '~'}
  SubDelims = {'!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '='}
  PChar = Unreserved + SubDelims + {':', '@'}

proc escaped(): TextParser[string] =
  (ch('%') & chars(HexDigits, "hex digit") & chars(HexDigits, "hex digit"))
    .flatten("escape").map(e => $chr(parseHexInt(e[1 .. 2])))

proc run(allowed: set[char], expected: string): TextParser[string] =
  ## A run of allowed characters and escapes, decoded. May be empty.
  (chars(allowed, expected).plus.flatten / escaped()).star.map(parts => parts.join)

proc refined(r: sink Ref): Ref =
  ## The schemes whose own syntax packs the party and the path into one
  ## segment.
  result = r
  if result.scheme.isNone or result.name.isSome or result.where.len != 1: return
  let s = result.where[0]
  case result.scheme.get
  of "did":
    let parts = s.split(':')
    if parts.len >= 2:
      result.name = some parts[0]
      result.where = parts[1 .. ^1]
  of "urn":
    let i = s.find(':')
    if i > 0:
      result.name = some s[0 ..< i]
      result.where = @[s[i + 1 .. ^1]]
  of "mailto":
    let i = s.rfind('@')
    if i > 0:
      result.user = some s[0 ..< i]
      result.name = some s[i + 1 .. ^1]
      result.where = @[]
  else: discard

proc assemble(m: sink Generic): Ref =
  var hier = move m[1]
  result = Ref(scheme: m[0], where: hier[1], how: m[2], which: m[3])
  if hier[0].isSome:
    let auth = move hier[0].get
    result.user = auth[0]
    result.name = some auth[1]
    result.port = auth[2]
  result = result.refined

proc node[V](make: Make[V], r: sink Ref): V =
  ## the five slots as a dict, each present only when said; what the
  ## reference holds moves into the value
  template txt(x: string): V = make.atom(bText, x, false)
  template key(x: string): V = make.atom(bSym, x, false)
  var es, who: seq[V]
  if r.scheme.isSome: es.add [key"scheme", make.atom(bSym, move r.scheme.get, false)]
  if r.user.isSome: who.add [key"user", txt(move r.user.get)]
  if r.name.isSome: who.add [key"name", txt(move r.name.get)]
  if r.port.isSome: who.add [key"port", make.atom(bNum, move r.port.get, false)]
  if who.len > 0: es.add [key"who", make.frame(bDict, who, false)]
  if r.where.len > 0:
    var segments: seq[V]
    for x in r.where.mitems: segments.add txt(move x)
    es.add [key"where", make.frame(bList, segments, false)]
  if r.how.isSome:
    var pairs: seq[V]
    for kv in r.how.get.mitems:
      pairs.add make.frame(bRec, @[txt(move kv[0]),
                                   if kv[1].isSome: txt(move kv[1].get) else: make.atom(bNil, "", false)], false)
    es.add [key"how", make.frame(bList, pairs, false)]
  if r.which.isSome: es.add [key"which", txt(move r.which.get)]
  make.frame(bDict, es, false)

proc reference(): TextParser[Ref] =
  let
    scheme = (letter() & chars(Letters + Digits + {'+', '-', '.'}, "scheme character").star)
      .flatten("scheme")
    user = run(Unreserved + SubDelims + {':'}, "user character")
    ipLiteral = delimited(ch('['), ch(']'), noneOf("]", "address character").plus.flatten)
    host = ipLiteral / run(Unreserved + SubDelims, "host character")
    port = (ch(':') & digit().plus.flatten("port")).pick(1)
    authority = (str("//") & sequence(((user & ch('@')).pick(0).optional, host, port.optional))).pick(1)
    segment = run(PChar, "path character")
    slashed = (ch('/') & segment).pick(1).star
    rootless = (segment.where(s => s.len > 0, "a path") & slashed).map((m: sink (string, seq[string])) => m[0] & m[1])
    hier = (authority & slashed).map((m: sink (Authority, seq[string])) => (some m[0], m[1])) /
      rootless.map((p: sink seq[string]) => (none(Authority), p)) /
      slashed.map((p: sink seq[string]) => (none(Authority), p))
    qchar = PChar + {'/', '?'}
    key = run(qchar - {'&', '='}, "query character")
    value = (ch('=') & run(qchar - {'&'}, "query character")).pick(1).optional
    how = (ch('?') & (key & value).starSeparated(ch('&')).elements).pick(1).optional
    which = (ch('#') & run(qchar, "fragment character")).pick(1).optional
    generic = sequence(((scheme & ch(':')).pick(0).optional, hier, how, which)).map(assemble)
    scp = sequence((run(Unreserved + SubDelims, "user character"), ch('@'), host, ch(':'), rootless))
      .map((m: sink (string, char, string, char, seq[string])) => Ref(user: some m[0], name: some m[2], where: m[4]))
    address = sequence((run(Unreserved + SubDelims, "user character"), ch('@'), host))
      .map((m: sink (string, char, string)) => Ref(user: some m[0], name: some m[2]))
  scp / address / generic

proc uriParser*[V](make: Make[V]): TextParser[V] =
  reference().map((r: sink Ref) => node(make, r)).trim.complete