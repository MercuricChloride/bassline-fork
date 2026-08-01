import std/unittest
import pkg/core
import pkg/lib/[read, print]
import pkg/lib/borth

proc boot(maxDepth = 100_000): Runtime =
  result = initRuntime(maxDepth)
  installCore(result)

proc feedText(rt: var Runtime, text: string) =
  rt.feedValue readDocument(text)

proc runText(text: string): Runtime =
  result = boot()
  result.feedText(text)
  result.run()

suite "the one rule":
  test "a mention pushes itself":
    let rt = runText("foo 5 \"hi\"")
    check rt.stack == @[sym"foo", num"5", text"hi"]

  test "a marked defined word executes":
    check runText("10 20 add!").stack == @[num"30"]

  test "a marked unknown is a refusal, not data":
    expect RuntimeError:
      discard runText("frobnicate!")

  test "a marked list is an anonymous call":
    check runText("![ 1 2 add! ]").stack == @[num"3"]

  test "a marked unknown frame refuses":
    expect RuntimeError:
      discard runText("!(go now)")

  test "words may be named by any value":
    check runText("[ \"five\" ] 5 define! 5!").stack == @[text"five"]

  test "a mention key must be a symbol":
    expect RuntimeError:
      discard runText("[ 1 ] 5 macro!")

suite "quotations and the machine":
  test "define and call":
    check runText("[ 10 20 add! ] foo define! foo!").stack == @[num"30"]

  test "a quotation is inert until done":
    let rt = runText("[ 1 2 add! ] do!")
    check rt.stack == @[num"3"]

  test "an empty quotation does nothing":
    check runText("[] do!").stack.len == 0

  test "tail calls are flat":
    var rt = boot()
    rt.feedText("[ spin! ] spin define! spin!")
    discard rt.pump(10_000)
    check rt.frames.len <= 2
    check not rt.done

  test "non-tail recursion refuses at the depth ceiling":
    var rt = boot(maxDepth = 100)
    rt.feedText("[ deep! 1 ] deep define! deep!")
    expect RuntimeError:
      rt.run()

  test "dip parks a value on the control stack":
    check runText("1 2 [ 10 add! ] dip!").stack == @[num"11", num"2"]

  test "dip restores across a tail call":
    let rt = runText("[ 100 add! ] bump define! 1 5 [ bump! ] dip!")
    check rt.stack == @[num"101", num"5"]

suite "macros and parse words":
  test "a macro fires on mention and reads its caller's phrase":
    let rt = runText("[ read-value! var! ] var macro! var greeting")
    check rt.isDefined(sym("greeting").mark(true))

  test "cells set and read":
    let rt = runText(
      "[ read-value! var! ] var macro! var greeting 42 greeting set! greeting!"
    )
    check rt.stack == @[num"42"]

  test "a macro inside a quotation reads that quotation":
    let rt = runText("[ read-value! ] grab macro! [ grab hello ] inner define! inner!")
    check rt.stack == @[sym"hello"]

  test "a macro at the top level reads the input":
    check runText("[ read-value! ] grab macro! grab world").stack == @[sym"world"]

  test "a call body reads its own body":
    let rt = runText("[ read-value! magic ] litword define! litword!")
    check rt.stack == @[sym"magic"]

  test "a starved read refuses":
    expect RuntimeError:
      discard runText("read-value!")

  test "read-until gathers to the stop value":
    let rt = runText("stop read-until! a b stop")
    check rt.stack == @[list(sym"a", sym"b")]

suite "each and map":
  test "each runs the quote per element":
    check runText("[ 1 2 3 ] [ 10 mul! ] each!").stack ==
      @[num"10", num"20", num"30"]

  test "each is fold: the accumulator lives on the stack":
    check runText("0 [ 1 2 3 ] [ add! ] each!").stack == @[num"6"]

  test "each over a dict pushes key then value":
    check runText("{ a: 1 b: 2 } [ swap! drop! ] each!").stack ==
      @[num"1", num"2"]

  test "each over a record visits fields, not the head":
    check runText("(h 1 2) [] each!").stack == @[num"1", num"2"]

  test "map rebuilds a list":
    check runText("[ 1 2 3 ] [ 10 mul! ] map!").stack ==
      @[list(num"10", num"20", num"30")]

  test "map keeps a record's head":
    check runText("(point 1 2) [ 10 mul! ] map!").stack ==
      @[record(sym"point", num"10", num"20")]

  test "map over a dict is two in, two out; keys survive untouched":
    check runText("{ a: 1 b: 2 } [ 10 mul! ] map!").stack ==
      @[dict((sym"a", num"10"), (sym"b", num"20"))]

  test "map that rewrites keys into collision refuses":
    expect RuntimeError:
      discard runText("{ a: 1 b: 2 } [ drop! drop! zz 0 ] map!")

  test "map holds the quote to its height contract":
    expect RuntimeError:
      discard runText("[ 1 ] [ dup! ] map!")

  test "map over a set dedups by constructor policy":
    check runText("{ 1 2 3 } [ drop! 9 ] map!").stack == @[set(num"9")]

suite "fuel":
  test "pump spends at most the quantum":
    var rt = boot()
    rt.feedText("[ spin! ] spin define! spin!")
    let spent = rt.pump(50)
    check spent == 50
    check not rt.done
