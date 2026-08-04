import std/[deques, strutils, unittest]
import pkg/core
import pkg/lib/[runtime, read, print]

proc asInt(v: Value): int =
  parseInt(string(v.num))

# a recorder: the transcript is its state
let recRead = stepIt:
  state = list(state.contents & it)

suite "delivery":
  test "a mailbox is fifo and drive is to quiescence":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead)
    let rec = rt.spawn(sym"rec", list())
    for i in 1 .. 3:
      rt.post rec, num($i)
    check not rt.done
    rt.drive()
    check rt.done
    check rt[rec].state == list(num"1", num"2", num"3")
    check rt[rec].reductions == 3

  test "processes take turns: one reduction each, round robin":
    # two full mailboxes drain interleaved, not one then the other
    var rt = initRuntime()
    let tagRead = stepIt:
      emit(sym"out", record(state, it))
    rt.install sym"tag", Behavior(read: tagRead)
    rt.install sym"rec", Behavior(read: recRead)
    let a = rt.spawn(sym"tag", sym"A")
    let b = rt.spawn(sym"tag", sym"B")
    let rec = rt.spawn(sym"rec", list())
    rt.wire a, sym"out", rec
    rt.wire b, sym"out", rec
    for i in 1 .. 3:
      rt.post a, num($i)
    for i in 1 .. 3:
      rt.post b, num($i)
    rt.drive()
    check rt[rec].state ==
      list(
        record(sym"A", num"1"),
        record(sym"B", num"1"),
        record(sym"A", num"2"),
        record(sym"B", num"2"),
        record(sym"A", num"3"),
        record(sym"B", num"3"),
      )

  test "pump runs a quantum and reports it":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead)
    let rec = rt.spawn(sym"rec", list())
    for i in 1 .. 10:
      rt.post rec, num($i)
    check rt.pump(4) == 4
    check not rt.done
    check rt[rec].mailbox.len == 6
    rt.drive()
    check rt[rec].state.contents.len == 10

suite "the mark split":
  test "read hears inert, exec hears marked":
    var rt = initRuntime()
    let countingRead = stepIt:
      state = list(num($(state.contents[0].asInt + 1)), state.contents[1])
    let countingExec = stepIt:
      state = list(state.contents[0], num($(state.contents[1].asInt + 1)))
    rt.install sym"counter", Behavior(read: countingRead, exec: countingExec)
    let c = rt.spawn(sym"counter", list(num"0", num"0"))
    rt.post c, sym"data"
    rt.post c, mark(record(sym"go"))
    rt.post c, num"7"
    rt.post c, mark(sym"go")
    rt.drive()
    check rt[c].state == list(num"2", num"2")
    check rt[c].dropped == 0

  test "a missing lane discards, and counts what it discarded":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead) # no exec lane
    let rec = rt.spawn(sym"rec", list())
    rt.post rec, sym"kept"
    rt.post rec, mark(sym"dropped")
    rt.post rec, mark(record(sym"dropped-too"))
    rt.drive()
    check rt[rec].state == list(sym"kept")
    check rt[rec].dropped == 2
    check rt[rec].reductions == 3 # a dropped message still cost its turn

suite "wiring":
  test "one label fans out to every destination":
    var rt = initRuntime()
    let fwdRead = stepIt:
      emit(sym"out", it)
    rt.install sym"fwd", Behavior(read: fwdRead)
    rt.install sym"rec", Behavior(read: recRead)
    let f = rt.spawn(sym"fwd")
    let r1 = rt.spawn(sym"rec", list())
    let r2 = rt.spawn(sym"rec", list())
    rt.wire f, sym"out", r1
    rt.wire f, sym"out", r2
    rt.post f, num"9"
    rt.drive()
    check rt[r1].state == list(num"9")
    check rt[r2].state == list(num"9")

  test "labels are values, mark-exact":
    var rt = initRuntime()
    let bothRead = stepIt:
      emit(sym"go", it)
      emit(mark(sym"go"), it)
    rt.install sym"both", Behavior(read: bothRead)
    rt.install sym"rec", Behavior(read: recRead)
    let b = rt.spawn(sym"both")
    let inertEar = rt.spawn(sym"rec", list())
    let markedEar = rt.spawn(sym"rec", list())
    rt.wire b, sym"go", inertEar
    rt.wire b, mark(sym"go"), markedEar
    rt.post b, num"1"
    rt.drive()
    check rt[inertEar].state == list(num"1")
    check rt[markedEar].state == list(num"1")

  test "speaking where nothing is wired is silence":
    var rt = initRuntime()
    let fwdRead = stepIt:
      emit(sym"nowhere", it)
    rt.install sym"fwd", Behavior(read: fwdRead)
    let f = rt.spawn(sym"fwd")
    rt.post f, num"1"
    rt.drive()
    check rt[f].reductions == 1 # it ran; nobody heard; nothing broke

suite "aliases":
  test "late binding: retargeting redirects every speaker":
    var rt = initRuntime()
    let fwdRead = stepIt:
      emit(sym"out", it)
    rt.install sym"fwd", Behavior(read: fwdRead)
    rt.install sym"rec", Behavior(read: recRead)
    let f = rt.spawn(sym"fwd")
    let r1 = rt.spawn(sym"rec", list())
    let r2 = rt.spawn(sym"rec", list())
    rt.wire f, sym"out", sym"printer" # by name, not by pid
    rt.alias sym"printer", r1
    rt.post f, num"1"
    rt.drive()
    rt.alias sym"printer", r2
    rt.post f, num"2"
    rt.drive()
    rt.unalias sym"printer"
    rt.post f, num"3" # a name nobody holds hears nothing
    rt.drive()
    check rt[r1].state == list(num"1")
    check rt[r2].state == list(num"2")

  test "any value names: a record alias beside a symbol alias":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead)
    let r = rt.spawn(sym"rec", list())
    let described = record(sym"someone", dict(@[(sym"named", sym"printer")]))
    rt.alias sym"printer", r
    rt.alias described, r
    rt.post sym"printer", num"1"
    rt.post described, num"2"
    rt.post sym"stranger", num"3" # unknown alias: silence
    rt.drive()
    check rt[r].state == list(num"1", num"2")

suite "lifecycle is local":
  test "sends to the dead are discarded, senders learn nothing":
    var rt = initRuntime()
    let fwdRead = stepIt:
      emit(sym"out", it)
    rt.install sym"fwd", Behavior(read: fwdRead)
    rt.install sym"rec", Behavior(read: recRead)
    let f = rt.spawn(sym"fwd")
    let r = rt.spawn(sym"rec", list())
    rt.wire f, sym"out", r
    rt.post f, num"1"
    rt.drive()
    rt.kill r
    check not rt[r].live
    rt.post f, num"2" # the speaker keeps speaking, unbothered
    rt.drive()
    check rt[f].reductions == 2
    check rt[r].state == list(num"1")

suite "cycles":
  test "self-sends run flat and are counted":
    var rt = initRuntime()
    let countRead = stepIt:
      if it.asInt == 0:
        emit(sym"landed", it)
      else:
        emit(sym"next", num($(it.asInt - 1)))
    rt.install sym"countdown", Behavior(read: countRead)
    rt.install sym"rec", Behavior(read: recRead)
    let down = rt.spawn(sym"countdown")
    let rec = rt.spawn(sym"rec", list())
    rt.wire down, sym"next", down
    rt.wire down, sym"landed", rec
    rt.post down, num"10000"
    rt.drive()
    check rt.done
    check rt[rec].state == list(num"0")
    check rt[down].reductions == 10001

suite "the runtime as a value":
  test "a restore continues from the state":
    # the fixture is confluent by design: turn order is run, not
    # state, so a restore begins the round in pid order
    proc build(): Runtime =
      result = initRuntime()
      let sumRead = stepIt:
        state = num($(state.asInt + it.asInt))
        emit(sym"out", state)
      result.install sym"summing", Behavior(read: sumRead)
      result.install sym"rec", Behavior(read: recRead)

    var one = build()
    let s1 = one.spawn(sym"summing", num"0")
    let r1 = one.spawn(sym"rec", list())
    one.wire s1, sym"out", sym"ear"
    one.alias sym"ear", r1
    for i in 1 .. 5:
      one.post s1, num($i)
    discard one.pump(3) # frozen mid-flight
    let frozen = one.snapshot()
    check frozen == one.snapshot() # snapshots are deterministic

    var two = build()
    two.restore frozen
    one.drive()
    two.drive()
    check two.snapshot() == one.snapshot()
    check two[Pid(1)].state == one[r1].state

  test "a snapshot speaks the textual syntax":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead)
    let r = rt.spawn(sym"rec", list(sym"held"))
    rt.post r, num"1" # mail in flight is part of the document
    rt.alias record(sym"someone", dict(@[(sym"named", sym"printer")])), r
    rt.wire r, sym"out", sym"printer"
    let doc = rt.snapshot()
    check readValue($doc) == doc

  test "restore is all-or-nothing":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead)
    let r = rt.spawn(sym"rec", list())
    rt.post r, num"1"
    let doc = rt.snapshot()

    var missing = initRuntime() # holds no behaviors at all
    expect ValueError:
      missing.restore doc
    var fresh = initRuntime()
    fresh.install sym"rec", Behavior(read: recRead)
    expect ValueError:
      fresh.restore mark(doc) # a snapshot is inert data
    fresh.restore doc
    fresh.drive()
    check fresh[Pid(0)].state == list(num"1")

  test "gone processes keep their slot and their silence":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead)
    let dead = rt.spawn(sym"rec", list())
    let live = rt.spawn(sym"rec", list())
    rt.kill dead
    rt.post live, num"1"
    let doc = rt.snapshot()
    var back = initRuntime()
    back.install sym"rec", Behavior(read: recRead)
    back.restore doc
    back.post Pid(0), num"9" # discarded: still dead after the trip
    back.drive()
    check not back[Pid(0)].live
    check back[Pid(1)].state == list(num"1")

suite "looking in":
  test "a process knows its own pid, and the window is lent":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead)
    let a = rt.spawn(sym"rec", list())
    let b = rt.spawn(sym"rec", list())
    check rt[a].pid == a
    check rt[b].pid == b
    # every field is there to read; none is there to write
    check not compiles((rt[a].state = num"9"))
    check not compiles((rt[a].mailbox.addLast num"9"))
    check not compiles((rt[a].live = false))
    # and pids survive the document trip: position is the pid
    rt.post b, num"1"
    let doc = rt.snapshot()
    var back = initRuntime()
    back.install sym"rec", Behavior(read: recRead)
    back.restore doc
    check back[b].pid == b
    check back[a].pid == a

suite "the reshaping law":
  test "a step may not reshape the runtime under itself":
    var rt = initRuntime()
    let trap = rt
    let naughty = stepIt:
      discard trap.spawn(sym"noop")
    rt.install sym"noop", Behavior(read: naughty)
    let p = rt.spawn(sym"noop")
    rt.post p, num"1"
    expect AssertionDefect:
      discard rt.step()

  test "a snapshot is a between-steps read":
    var rt = initRuntime()
    let trap = rt
    let sneaky = stepIt:
      discard trap.snapshot()
    rt.install sym"sneaky", Behavior(read: sneaky)
    let p = rt.spawn(sym"sneaky")
    rt.post p, num"1"
    expect AssertionDefect:
      discard rt.step()

suite "errors are messages when someone listens":
  let angryRead = stepIt:
    if it == sym"boom":
      raise newException(CatchableError, "bang")
    state = list(state.contents & it)

  test "held: a raise becomes (raised …) and the runtime keeps going":
    var rt = initRuntime()
    rt.install sym"angry", Behavior(read: angryRead)
    rt.install sym"rec", Behavior(read: recRead)
    let a = rt.spawn(sym"angry", list())
    let ear = rt.spawn(sym"rec", list())
    rt.alias ErrorsName, ear
    rt.post a, num"1"
    rt.post a, sym"boom"
    rt.post a, num"2"
    rt.drive() # no raise reaches the driver
    check rt[a].state == list(num"1", num"2")
    check rt[ear].state ==
      list(record(sym"raised", sym"angry", sym"boom", text"bang"))

  test "unheld: it propagates, and the process keeps its remaining mail":
    var rt = initRuntime()
    rt.install sym"angry", Behavior(read: angryRead)
    let a = rt.spawn(sym"angry", list())
    rt.post a, num"1"
    rt.post a, sym"boom"
    rt.post a, num"2"
    expect CatchableError:
      rt.drive()
    check not rt.done # the remaining mail is still runnable
    rt.drive()
    check rt[a].state == list(num"1", num"2")

  test "the listener's own raise propagates":
    var rt = initRuntime()
    rt.install sym"angry", Behavior(read: angryRead)
    let a = rt.spawn(sym"angry", list())
    rt.alias ErrorsName, a # its own listener
    rt.post a, sym"boom"
    expect CatchableError:
      rt.drive()

  test "a dead listener means propagation, not silence":
    var rt = initRuntime()
    rt.install sym"angry", Behavior(read: angryRead)
    rt.install sym"rec", Behavior(read: recRead)
    let a = rt.spawn(sym"angry", list())
    let ear = rt.spawn(sym"rec", list())
    rt.alias ErrorsName, ear
    rt.kill ear
    rt.post a, sym"boom"
    expect CatchableError:
      rt.drive()

suite "the unheard name":
  test "a lane-miss reports, and a marked message rides wrapped inert":
    var rt = initRuntime()
    rt.install sym"deaf", Behavior(read: recRead) # no exec lane
    rt.install sym"rec", Behavior(read: recRead)
    let d = rt.spawn(sym"deaf", list())
    let ear = rt.spawn(sym"rec", list())
    rt.alias UnheardName, ear
    rt.post d, mark(sym"order")
    rt.drive()
    check rt[d].dropped == 1
    check rt[ear].state == list(record(sym"unheard", sym"deaf", mark(sym"order")))

  test "a send to the dead reports (gone …) — a local fact, locally spoken":
    var rt = initRuntime()
    let fwdRead = stepIt:
      emit(sym"out", it)
    rt.install sym"fwd", Behavior(read: fwdRead)
    rt.install sym"rec", Behavior(read: recRead)
    let f = rt.spawn(sym"fwd")
    let r = rt.spawn(sym"rec", list())
    let ear = rt.spawn(sym"rec", list())
    rt.wire f, sym"out", r
    rt.alias UnheardName, ear
    rt.kill r
    rt.post f, num"5" # emitted onward to the dead
    rt.drive()
    check rt[ear].state == list(record(sym"gone", sym"rec", num"5"))
    rt.post r, num"6" # a direct post to the dead reports too
    rt.drive()
    check rt[ear].state.contents.len == 2

  test "reports are never about their own listener":
    var rt = initRuntime()
    rt.install sym"execonly", Behavior(exec: recRead) # drops inert mail
    let d = rt.spawn(sym"execonly", list())
    rt.alias UnheardName, d # its own drops would report to itself
    rt.post d, sym"plain"
    rt.drive() # terminates: the self-report is skipped
    check rt[d].dropped == 1
    check rt[d].state == list()

suite "rewiring and looking around":
  test "unwire removes one destination, or the label":
    var rt = initRuntime()
    let fwdRead = stepIt:
      emit(sym"out", it)
    rt.install sym"fwd", Behavior(read: fwdRead)
    rt.install sym"rec", Behavior(read: recRead)
    let f = rt.spawn(sym"fwd")
    let r1 = rt.spawn(sym"rec", list())
    let r2 = rt.spawn(sym"rec", list())
    rt.wire f, sym"out", r1
    rt.wire f, sym"out", r2
    rt.wire f, sym"out", sym"printer"
    rt.alias sym"printer", r1
    rt.unwire f, sym"out", r1 # drop one early-bound ear
    rt.post f, num"1"
    rt.drive()
    check rt[r1].state == list(num"1") # via the alias only
    check rt[r2].state == list(num"1")
    rt.unwire f, sym"out", sym"printer" # drop the late-bound one
    rt.post f, num"2"
    rt.drive()
    check rt[r1].state == list(num"1")
    check rt[r2].state == list(num"1", num"2")
    rt.unwire f, sym"out" # drop the whole label
    rt.post f, num"3"
    rt.drive()
    check rt[r2].state == list(num"1", num"2")
    rt.unwire f, sym"never" # unwiring the unwired is silence

  test "the window reaches the tables":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead)
    let a = rt.spawn(sym"rec", list())
    let b = rt.spawn(sym"rec", list())
    rt.wire a, sym"out", b
    rt.wire a, sym"out", sym"printer"
    rt.wire b, sym"back", a
    rt.alias sym"printer", b
    var routeCount, destCount, aliasCount, behaviorCount = 0
    for (src, label, dests) in rt.eachRoute:
      inc routeCount
      destCount += dests.len
      for d in dests:
        if d.kind == dAlias:
          check d.name == sym"printer"
    for (name, pid) in rt.eachAlias:
      inc aliasCount
      check name == sym"printer" and pid == b
    for k in rt.eachBehavior:
      inc behaviorCount
      check k == sym"rec"
    check routeCount == 2
    check destCount == 3
    check aliasCount == 1
    check behaviorCount == 1

  test "lastReduced points at the turn just taken":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead)
    let a = rt.spawn(sym"rec", list())
    let b = rt.spawn(sym"rec", list())
    rt.post a, num"1"
    rt.post b, num"2"
    discard rt.step()
    check rt.lastReduced == a
    discard rt.step()
    check rt.lastReduced == b

suite "restore refuses the unspoken":
  test "refusal is whole: nothing commits, and a retry succeeds":
    var rt = initRuntime()
    rt.install sym"rec", Behavior(read: recRead)
    # the second proc names a behavior nobody holds
    let bad = readValue"(runtime [(proc rec [] [1]) (proc nope [] [])] {:} [])"
    expect ValueError:
      rt.restore bad
    check rt.len == 0 # all-or-nothing means nothing
    rt.restore readValue"(runtime [(proc rec [] [1])] {:} [])"
    rt.drive()
    check rt[Pid(0)].state == list(num"1")

  test "the accepted dialect is exactly the spoken one":
    let badDocs = [
      "(runtime [(gone 1)] {:} [])", # gone is (gone)
      "(runtime [(proc rec [] [])] {ear: 1} [])", # a pid is a position
      "(runtime [(proc rec [] [])] {ear: -1} [])",
      "(runtime [(proc rec [] [])] {ear: 3000000000} [])",
      "(runtime [(proc rec [] [])] {ear: 99999999999999999999} [])",
      "(runtime [!(proc rec [] [])] {:} [])", # structure is inert
      "(runtime [(proc rec [] [])] {:} [!(route 0 out [(pid 0)])])",
      "(runtime [(proc rec [] [])] {:} [(route 0 out [!(pid 0)])])",
      "(runtime [(proc rec [] [])] {ear: 0!} [])", # a pid is inert
      "(runtime [(proc rec [] [])] {:} [(route 0 out [(pid 0)]) (route 0 out [(pid 0)])])",
        # two routes for one (from, label)
    ]
    for spelling in badDocs:
      var rt = initRuntime()
      rt.install sym"rec", Behavior(read: recRead)
      expect ValueError:
        rt.restore readValue(spelling)
      check rt.len == 0

  test "marked mail still instructs after the trip":
    var rt = initRuntime()
    let markCount = stepIt:
      state = num($(state.asInt + 1))
    rt.install sym"counter", Behavior(exec: markCount)
    let c = rt.spawn(sym"counter", num"0")
    rt.post c, mark(record(sym"go"))
    let doc = rt.snapshot() # the instruction is in flight
    var back = initRuntime()
    back.install sym"counter", Behavior(exec: markCount)
    back.restore doc
    back.drive()
    check back[Pid(0)].state == num"1"
