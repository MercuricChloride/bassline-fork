import std/[options, macros]
export options

type
  Search[T] = object
    sources: iterator: Option[T]

proc initSearch*[T](sources: iterator: Option[T]): Search[T] =
  Search[T](sources: sources)

proc finished*[T](s: Search[T]): bool =
  s.sources.finished

iterator items*[T](s: Search[T]): T =
  for each in s.sources():
    if each.isNone: continue
    elif s.finished: break
    else: yield each.get

template search*(T, body): untyped =
  Search[T](sources: (iterator: Option[T] = body))