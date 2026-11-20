import std/unittest
import tinybl/[micro, micro_macros, tracks]

type
  Listener = ref object of Monitor
    onAdd: proc(i: int, entry: Entry)
    onRevise: proc(previous: openArray[Swap])
  Unique = ref object of Track
  Gate = ref object of Track

method added(self: Listener, i: int, entry: Entry) =
  if not self.onAdd.isNil: self.onAdd(i, entry)

method revised(self: Listener, previous: openArray[Swap]) =
  if not self.onRevise.isNil: self.onRevise(previous)

method keeps(self: Unique, n: Node): bool =
  for i in 0..<self.len:
    if self[i] == Present(n: n): return false
  true

method keeps(self: Gate, n: Node): bool =
  if n == bl"bad": raise newException(ValueError, "admission failed")
  true

suite "track writes":
  test "immediate and queued additions use the current admission policy":
    let t = Unique()
    var receipts: seq[Contribution]
    let listener = Listener(onAdd: proc(i: int, entry: Entry) =
      if i == 0:
        receipts.add t.add(bl"reply")
        receipts.add t.add(bl"reply"))
    listener.track = t
    check t.add(bl"first") == Contribution.Kept
    check receipts == @[Contribution.Staged, Contribution.Staged]
    check t.add(bl"reply") == Contribution.Ignored
    check t.len == 2
    check t[1] == Present(n: bl"reply")

  test "changed and unchanged revisions drain additions in the same order":
    for changed in [false, true]:
      let t = Track()
      t.add bl"original"
      var seen: seq[Entry]
      var revisions = 0
      let responder = Listener(onAdd: proc(i: int, entry: Entry) =
        if entry == Present(n: bl"first"):
          check t.add(bl"third") == Contribution.Staged)
      let watcher = Listener()
      watcher.onAdd = proc(i: int, entry: Entry) =
        check i == seen.len + 1
        seen.add entry
      watcher.onRevise = proc(previous: openArray[Swap]) =
        inc revisions
        check seen.len == 0
        check previous.len == 1
        check previous[0].idx == 0
        check previous[0].entry == Present(n: bl"original")
        check t[0] == Present(n: bl"edited")
      responder.track = t
      watcher.track = t
      t.reviseIt:
        it[0] = bl"edited"
        if not changed: it[0] = bl"original"
        check t.add(bl"first") == Contribution.Staged
        check t.add(bl"second") == Contribution.Staged
      check seen == @[Present(n: bl"first"), Present(n: bl"second"), Present(n: bl"third")]
      check revisions == ord(changed)

  test "a refused draft keeps the committed slots and discards staged adds":
    let t = Track()
    t.add bl"original"
    expect BasslineError:
      t.reviseIt:
        it[0] = bl"edited"
        check it[0] == Present(n: bl"edited")
        check t[0] == Present(n: bl"original")
        check t.add(bl"discarded") == Contribution.Staged
        it.delete(it.len)
    check t[0] == Present(n: bl"original")
    check t.add(bl"next") == Contribution.Kept
    check t.len == 2

  test "a failing admission drains later entries and releases the writer":
    let t = Gate()
    let listener = Listener(onAdd: proc(i: int, entry: Entry) =
      if i == 0:
        t.add bl"bad"
        t.add bl"later")
    listener.track = t
    expect ValueError: discard t.add(bl"first")
    check t.len == 2
    check t[1] == Present(n: bl"later")
    t.reviseIt: it.delete(0)
    check t[0] == Absent()
    check t.add(bl"next") == Contribution.Kept

  test "failed hooks surface after the committed revision and queued additions":
    let t = Track()
    t.add bl"original"
    var seen: seq[Entry]
    let failing = Listener()
    failing.onRevise = proc(previous: openArray[Swap]) =
      check t.add(bl"from-hook") == Contribution.Staged
      raise newException(ValueError, "revision observer failed")
    failing.onAdd = proc(i: int, entry: Entry) =
      raise newException(ValueError, "addition observer failed")
    failing.track = t
    let watcher = Listener(onAdd: proc(i: int, entry: Entry) = seen.add entry)
    watcher.track = t
    var failure = ""
    try:
      t.reviseIt:
        it.delete(0)
        t.add bl"from-draft"
    except ValueError as e:
      failure = e.msg
    check failure == "revision observer failed"
    check t[0] == Absent()
    check seen == @[Present(n: bl"from-draft"), Present(n: bl"from-hook")]
    expect ValueError:
      t.reviseIt: t.add bl"from-empty-draft"
    check seen[^1] == Present(n: bl"from-empty-draft")

  test "a monitor can detach during a revision without skipping the next one":
    let t = Track()
    t.add bl"original"
    let leaving = Listener()
    leaving.onRevise = proc(previous: openArray[Swap]) = leaving.track = nil
    var calls = 0
    let staying = Listener(onRevise: proc(previous: openArray[Swap]) = inc calls)
    leaving.track = t
    staying.track = t
    t.reviseIt: it.delete(0)
    check leaving.track.isNil
    check calls == 1
