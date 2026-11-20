## pages.nim
## =========================================================================
## The shared page vocabulary every storage backend speaks. A backend is
## an arena of PageSize-byte pages addressed by page number; the tree in
## store.nim is written against this interface and nothing else — it
## never assumes contiguity ACROSS pages, only within one.
##
## A backend provides (see mmaparena.nim / memarena.nim for the two
## instances):
##
##   pageAt(a; pgno: PageN): Page    stable address of page pgno. MUST
##                                   stay valid and immovable until
##                                   close — the tree holds Page
##                                   pointers across allocations, and
##                                   zero-copy spans borrow them.
##   ensure(a: var; pages: int)      make pages [0, pages) addressable
##   publish(a: var; first: PageN; count: int)
##                                   commit-protocol write-back (msync);
##                                   no-op in memory
##   barrier(a: var)                 durability fence (F_FULLFSYNC);
##                                   no-op in memory
##   trim(a: var; pages: int64)      shrink content to exactly `pages`
##                                   pages (EOF = published, the
##                                   recovery scan's anchor); no-op in
##                                   memory
##   seal(a: var; limit: PageN)      enforcement hook: pages below
##                                   `limit` are committed and must
##                                   never be written again (mprotect);
##                                   no-op in memory
##   contentPages(a): int64          pages of existing content, for the
##                                   recovery scan's starting probe
##   close(a: var)                   release everything
##
## pageAt is the hot path and is a template in both backends (inline
## procs die at module boundaries); the rest are cold procs.
## =========================================================================

const
  ReservedGb* {.intdefine.}: int = 64
  PageSize* {.intdefine.}: int = 16 * 1024
  GrowChunk* = 4 * 1024 * 1024      # growth granularity (bytes): file
                                    # extension steps for mmap, chunk
                                    # size for mem
type
  PageN* = uint32                   # 0 = nil (page 0 is the superblock,
                                    # so 0 is never a valid tree page)
  Page* = ptr array[PageSize, byte]

static:
  doAssert (PageSize and (PageSize - 1)) == 0, "PageSize must be a power of two"
  doAssert GrowChunk mod PageSize == 0