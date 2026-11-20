## lang: a dialect done by one doer, the stack dialect in examples/lang

import std/unittest
import bl/lang
import ../examples/lang/rpn

proc vs(texts: varargs[string]): seq[Value] =
  for t in texts: result.add readValue(t)

var refusals: seq[string]
proc cx(): Cx =
  refusals = @[]
  result = base(refused = (e: ref BasslineError) => refusals.add e.msg)
  result.install(rpn())

proc answers(text: string): seq[Value] = toSeq(cx().eval(readValue(text)))

template answersAre(text: string, expected: varargs[string]) =
  check answers(text) == vs(expected)

template refuses(text: string) =
  expect BasslineError:
    discard answers(text)

suite "the stack dialect":
  test "its words work the stack":
    answersAre "!(rpn [2 3 add 4 mul])", "20"
    answersAre "!(rpn [1 2 swap sub])", "1"
    answersAre "!(rpn [5 dup mul])", "25"
    answersAre "!(rpn [3 4 over add add])", "10"
    answersAre "!(rpn [3 4 drop])", "3"

  test "what isn't a word is pushed as it is, a frame unlooked into":
    answersAre "!(rpn [\"hi\"])", "\"hi\""
    answersAre "!(rpn [[!(add 1 2)]])", "[!(add 1 2)]"

  test "a marked word is handed back, and each answer pushed":
    answersAre "!(rpn [!(add 1 2) 10 mul])", "30"
    answersAre "!(rpn [!(in [1 2 3]) dup mul])", "1", "4", "9"

  test "its answers are answers like any other":
    answersAre "!(add !(rpn [6 7 mul]) 1)", "43"
    answersAre "![!(rpn [1]) !(rpn [2])]", "[1 2]"

  test "its arithmetic is whatever doers are in reach":
    let near = cx().within()
    near.install(rules([readValue"(rule (shape !(mul a b) {a b}) [!(record times a! b!)])"]))
    check toSeq(near.eval(readValue"!(rpn [6 7 mul])")) == vs("(times 6 7)")

  test "a word whose call answers nothing ends its branch":
    answersAre "!(rpn [!(in [1 5 2 7]) dup 4 lt])", "1", "2"
    answersAre "!(rpn [5 4 lt])"

  test "a branch that refuses has nothing, and the others go on":
    let c = cx()
    check toSeq(c.eval(readValue"!(rpn [12 !(in [1 0 2]) div])")) == vs("12", "6")
    check refusals.len > 0

  test "a symbol it has no word for, or too little on the stack, refuses":
    refuses "!(rpn [1 2 frob])"
    refuses "!(rpn [1 add])"
    refuses "!(rpn [])"

  test "it says what it does":
    answersAre "!(describe rpn)",
      "(rpn [dup drop swap over] {add: 2 compare: 2 div: 2 eq: 2 ge: 2 gt: 2 le: 2 lt: 2 mod: 2 mul: 2 ne: 2 sub: 2})"
