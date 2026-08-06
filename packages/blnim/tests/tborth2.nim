import std/unittest
import pkg/core
import pkg/lib/[reader, borth]

const Prelude = staticRead("../src/lib/borth/prelude.bl")

proc boot(): Runtime =
  result = initRuntime()
  installCore(result)

proc feedText(rt: var Runtime, text: string) =
  rt.feedValue readDocument(text)

proc runText(text: string): Runtime =
  ## vocabulary tests run over the full standard surface: core + prelude
  result = boot()
  result.feedText(Prelude)
  result.run()
  result.feedText(text)
  result.run()

proc runPrelude(text: string): Runtime =
  runText(text)

suite "fry":
  test "positive holes insert by depth from the top":
    check runText("\"bob\" 42 { name: 2! age: 1! } fry!").stack ==
      @[dict((sym"name", text"bob"), (sym"age", num"42"))]

  test "repetition is dup":
    check runText("7 [ 1! 1! mul! ] fry!").stack ==
      @[list(num"7", num"7", sym("mul").mark(true))]

  test "the window is the deepest reach; shallower unreferenced drop":
    check runText("a b [ 2! ] fry!").stack == @[list(sym"a")]

  test "a template reaching past the stack refuses":
    expect RuntimeError:
      discard runText("1 [ 2! ] fry!")

  test "zero names nothing":
    expect RuntimeError:
      discard runText("1 [ 0! ] fry!")

  test "negative holes splice children":
    check runText("[ 1 2 ] [ a -1! b ] fry!").stack ==
      @[list(sym"a", num"1", num"2", sym"b")]

  test "splicing a non-frame refuses":
    expect RuntimeError:
      discard runText("5 [ -1! ] fry!")

  test "a record template can splice":
    check runText("[ 9 ] (h -1!) fry!").stack == @[record(sym"h", num"9")]

  test "a dict entry cannot splice":
    expect RuntimeError:
      discard runText("[ 1 ] { -1! : x } fry!")

  test "window values are opaque: spliced holes pass through":
    check runText("[ 1! ] [ -1! ] fry!").stack ==
      @[list(num("1", marked = true))]

  test "window values are opaque: inserted values are not re-scanned":
    check runText("[ 5! ] [ 1! ] fry!").stack ==
      @[list(list(num("5", marked = true)))]

  test "a holeless template consumes nothing":
    check runText("9 [ a b ] fry!").stack == @[num"9", list(sym"a", sym"b")]

  test "holes reach any depth of the template":
    check runText("9 [ [ 1! ] ] fry!").stack == @[list(list(num"9"))]

  test "post-fry keys colliding refuses":
    expect RuntimeError:
      discard runText("x x { 1!: 1 2!: 2 } fry!")

suite "builders":
  test "cons and cat":
    check runText("9 [ a b ] cons!").stack == @[list(num"9", sym"a", sym"b")]
    check runText("[ a ] [ b c ] cat!").stack == @[list(sym"a", sym"b", sym"c")]

  test "->list spills any frame in canonical order":
    check runText("{ b: 2 a: 1 } ->list!").stack ==
      @[list(sym"a", num"1", sym"b", num"2")]

  test "the round-trip law":
    check runText("{ b: 2 a: 1 } ->list! ->dict!").stack ==
      @[dict((sym"a", num"1"), (sym"b", num"2"))]
    check runText("{ 3 1 2 } ->list! ->set!").stack ==
      @[set(num"1", num"2", num"3")]
    check runText("(h 1) ->list! ->record!").stack == @[record(sym"h", num"1")]

  test "->record needs a head":
    expect RuntimeError:
      discard runText("[] ->record!")

  test "->dict refuses odd lists and duplicate keys":
    expect RuntimeError:
      discard runText("[ a ] ->dict!")
    expect RuntimeError:
      discard runText("[ a 1 a 2 ] ->dict!")

  test "merge is one operation: keyed refuses collision, keyless unions":
    check runText("{ a: 1 } { b: 2 } merge!").stack ==
      @[dict((sym"a", num"1"), (sym"b", num"2"))]
    expect RuntimeError:
      discard runText("{ a: 1 } { a: 2 } merge!")
    check runText("{ 1 2 } { 2 3 } merge!").stack ==
      @[set(num"1", num"2", num"3")]
    expect RuntimeError:
      discard runText("{ a: 1 } { 2 } merge!")

  test "put is last-wins by key or position":
    check runText("{ a: 1 } a 9 put!").stack == @[dict((sym"a", num"9"))]
    check runText("{ a: 1 } b 2 put!").stack ==
      @[dict((sym"a", num"1"), (sym"b", num"2"))]
    check runText("[ x y ] 1 z put!").stack == @[list(sym"x", sym"z")]

  test "difference is whole-collection and total":
    check runText("{ 1 2 3 } { 1 3 } difference!").stack == @[set(num"2")]
    check runText("{ 1 } { 9 } difference!").stack == @[set(num"1")]
    check runText("{ a: 1 b: 2 } { a: 1 } difference!").stack ==
      @[dict((sym"b", num"2"))]
    check runText("{ a: 1 } { a: 2 } difference!").stack ==
      @[dict((sym"a", num"1"))]

  test "set algebra is same-kind; casts are said out loud":
    expect RuntimeError:
      discard runText("[ a b ] { a } difference!")
    expect RuntimeError:
      discard runText("{ 1 2 } 1 difference!")
    expect RuntimeError:
      discard runText("{ a: 1 b: 2 } { a } difference!")

suite "readers":
  test "at answers dicts, positions, and refuses absence":
    check runText("{ a: 1 } a at!").stack == @[num"1"]
    check runText("[ a b ] 1 at!").stack == @[sym"b"]
    expect RuntimeError:
      discard runText("{ a: 1 } q at!")
    expect RuntimeError:
      discard runText("[ a b ] 5 at!")

  test "sets answer has?, not at":
    expect RuntimeError:
      discard runText("{ 1 2 } 1 at!")
    check runText("{ 1 2 } 1 has?!").stack == @[sym"present"]
    check runText("{ 1 2 } 9 has?!").stack == @[sym"absent"]

  test "has? on dicts asks about keys":
    check runText("{ a: 1 } a has?!").stack == @[sym"present"]
    check runText("{ a: 1 } 1 has?!").stack == @[sym"absent"]

  test "len counts entries for dicts, children elsewhere":
    check runText("[ a b c ] len!").stack == @[num"3"]
    check runText("{ a: 1 b: 2 } len!").stack == @[num"2"]
    check runText("(h 1 2) len!").stack == @[num"3"]
    expect RuntimeError:
      discard runText("5 len!")

  test "first and rest":
    check runText("[ a b ] first!").stack == @[sym"a"]
    check runText("[ a b ] rest!").stack == @[list(sym"b")]
    check runText("(h 1 2) first!").stack == @[sym"h"]
    check runText("(h 1 2) rest!").stack == @[list(num"1", num"2")]
    expect RuntimeError:
      discard runText("[] first!")

  test "keys and vals are set views":
    check runText("{ a: 1 b: 1 } keys!").stack == @[set(sym"a", sym"b")]
    check runText("{ a: 1 b: 1 } vals!").stack == @[set(num"1")]

  test "cmp answers a verdict symbol over the total order":
    check runText("1 2 cmp!").stack == @[sym"lt"]
    check runText("2 2 cmp!").stack == @[sym"eq"]
    check runText("2 1 cmp!").stack == @[sym"gt"]

  test "cmp is spelling order; num-cmp is counting order":
    check runText("-5 0 cmp!").stack == @[sym"gt"]
    check runText("-5 0 num-cmp!").stack == @[sym"lt"]
    check runText("-10 -5 num-cmp!").stack == @[sym"lt"]

  test "num-cmp refuses past the machine range, like the arithmetic":
    expect RuntimeError:
      discard runText("99999999999999999999 1 num-cmp!")

  test "kind names the kind":
    check runText("5 kind!").stack == @[sym"num"]
    check runText("[] kind!").stack == @[sym"list"]

  test "mark words":
    check runText("go mark! marked?!").stack == @[sym"marked"]
    check runText("go marked?!").stack == @[sym"unmarked"]

suite "bindings as dictionaries":
  test "a quote's binding speaks evaluator and value":
    check runText("[ 1 ] q define! q mark! binding!").stack ==
      @[dict((sym"evaluator", sym"quote"), (sym"value", list(num"1")))]

  test "a cell's binding speaks its value":
    check runText("greeting var! 42 greeting set! greeting mark! binding!").stack ==
      @[dict((sym"evaluator", sym"cell"), (sym"value", num"42"))]

  test "a primitive's binding speaks its traits":
    check runText("add mark! binding!").stack ==
      @[dict((sym"evaluator", sym"primitive"), (sym"traits", set(sym"protected")))]

  test "annotate merges open bindings, last wins":
    let rt = runText(
      "[ 1 ] q define! " & "q mark! { category: { math } } annotate! " &
        "q mark! { category: { arith } } annotate! " & "q mark! binding!"
    )
    check rt.stack ==
      @[
        dict(
          (sym"category", set(sym"arith")),
          (sym"evaluator", sym"quote"),
          (sym"value", list(num"1")),
        )
      ]

  test "the reserved entries are not open":
    expect RuntimeError:
      discard runText("[ 1 ] q define! q mark! { value: 5 } annotate!")
    expect RuntimeError:
      discard runText("q { a: 1 } annotate!")

  test "the dictionary is one value":
    let rt = runText("[ 1 ] q define! dictionary! q mark! at!")
    check rt.stack ==
      @[dict((sym"evaluator", sym"quote"), (sym"value", list(num"1")))]

suite "refusal honesty":
  test "division by zero refuses":
    expect RuntimeError:
      discard runText("1 0 div!")

  test "arithmetic past the machine range refuses":
    expect RuntimeError:
      discard runText("99999999999999999999 1 add!")

  test "a negative take refuses":
    expect RuntimeError:
      discard runText("-1 take!")

  test "set and read guard cells":
    expect RuntimeError:
      discard runText("5 nocell set!")
    expect RuntimeError:
      discard runText("[ 1 ] q define! 7 q set!")

  test "var is idempotent":
    let rt = runText("greeting var! greeting var!")
    check rt.isDefined(sym("greeting").mark(true))

suite "prelude":
  test "prefix definitions":
    check runPrelude("def double [ 2 mul! ] 21 double!").stack == @[num"42"]

  test "fry prefix form":
    check runPrelude("5 fry [ 1! ]").stack == @[list(num"5")]

  test "lit takes the next value untouched":
    check runPrelude("lit fry").stack == @[sym"fry"]

  test "case dispatches on a verdict":
    check runPrelude("1 2 cmp! { lt: [ yes ] eq: [ no ] gt: [ no ] } case!").stack ==
      @[sym"yes"]

  test "->entry builds the 1-ary dict":
    check runPrelude("a 1 ->entry!").stack == @[dict((sym"a", num"1"))]

  test "entries fold under merge":
    check runPrelude("a 1 ->entry! b 2 ->entry! merge!").stack ==
      @[dict((sym"a", num"1"), (sym"b", num"2"))]

  test "symmetric difference and inclusion derive in the prelude":
    check runPrelude("{ 1 2 3 } { 2 3 4 } sym-diff!").stack ==
      @[set(num"1", num"4")]
    check runPrelude("{ 1 2 } { 1 2 3 } included?!").stack == @[sym"included"]
    check runPrelude("{ 1 9 } { 1 2 3 } included?!").stack == @[sym"excluded"]

  test "inclusion reads dicts as sub-dicts":
    check runPrelude("{ a: 1 } { a: 1 b: 2 } included?!").stack ==
      @[sym"included"]
    check runPrelude("{ a: 9 } { a: 1 b: 2 } included?!").stack ==
      @[sym"excluded"]

  test "key-space difference is spelled, not lifted":
    check runPrelude("{ a: 1 b: 2 } { a } drop-keys!").stack ==
      @[dict((sym"b", num"2"))]
    check runPrelude("{:} { a } drop-keys!").stack == @[dict(newSeq[Entry]())]

  test "over and keep":
    check runPrelude("1 2 over!").stack == @[num"1", num"2", num"1"]
    check runPrelude("5 [ 10 add! ] keep!").stack == @[num"15", num"5"]

  test "rot brings the third to the top":
    check runPrelude("1 2 3 rot!").stack == @[num"2", num"3", num"1"]

  test "splice scatters a list":
    check runPrelude("[ 1 2 ] splice!").stack == @[num"1", num"2"]

  test "iota counts flat, by tail recursion":
    check runPrelude("3 iota!").stack == @[list(num"0", num"1", num"2")]
    check runPrelude("0 iota!").stack == @[list()]
    check runPrelude("-1 iota!").stack == @[list()]
    check runPrelude("1000 iota! len!").stack == @[num"1000"]

  test "rest refuses what it cannot take apart":
    expect RuntimeError:
      discard runPrelude("{ a: 1 } rest!")

  test "assignment reads infix":
    check runPrelude("var x x = 42 x!").stack == @[num"42"]

suite "the machine range refuses":
  test "arithmetic at the edge is a refusal, not a defect":
    expect RuntimeError:
      discard runText("9223372036854775807 1 add!")
    expect RuntimeError:
      discard runText("-9223372036854775808 1 sub!")
    expect RuntimeError:
      discard runText("9223372036854775807 2 mul!")
    expect RuntimeError:
      discard runText("-9223372036854775808 -1 div!")

suite "casts change the reading":
  test "keys, vals and ->dict do not carry the mark":
    check runText("{ a: 1 b: 2 } mark! keys!").stack ==
      @[set(sym"a", sym"b")]
    check runText("{ a: 1 b: 2 } mark! vals!").stack ==
      @[set(num"1", num"2")]
    check runText("[ a 1 ] mark! '->dict'!").stack ==
      @[dict(@[(sym"a", num"1")])]
