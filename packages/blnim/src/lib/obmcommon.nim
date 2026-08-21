include pkg/prelude

import std/options

import pkg/core
import ./obm

export obm, options

type
  BlFileInfo* {.blDict.} = object
    name*: Option[string]
    zip*: Option[Sym]

  BlFile* {.blRecord: sym"file".} = object
    contents*: seq[byte]
    info*: Option[BlFileInfo]

  Directory* {.blRecord: sym"directory".} = object
    entries* {.blSet.}: seq[Value]
    info*: Option[BlFileInfo]

  Digest* {.blRecord: sym"digest".} = object
    algo*: Sym
    hash*: seq[byte]

  Chunk* {.blRecord: sym"chunk".} = object
    ## A bounded run of a file's bytes, naming the chunk before it.
    ## A root chunk names nothing -- nil is how a chunk says it starts
    ## a file, rather than by an offset that happens to be zero.
    ##
    ## Chaining means two files that begin the same way share the
    ## chunks they begin with, and that a chunk cannot be quietly
    ## moved: its name commits to everything ahead of it.
    prev*: Option[Digest]
    bytes*: seq[byte]

  FileManifest* {.blRecord: sym"file".} = object
    ## (file <root> [<leaf>...] {name: ...}) -- a file said as the
    ## names of its chunks, in byte order. Recognition is strict about
    ## arity, so this and the whole-contents BlFile share the head
    ## `file` without either being mistaken for the other.
    root*: Digest
    leaves*: seq[Digest]
    info*: Option[BlFileInfo]

  DirManifest* {.blRecord: sym"dir".} = object
    ## (dir <root> [<child>...] {name: ...}) -- the names of the
    ## manifests under it, in CE order. Each child says its own name,
    ## so the list needs to carry nothing but names.
    root*: Digest
    entries*: seq[Digest]
    info*: Option[BlFileInfo]