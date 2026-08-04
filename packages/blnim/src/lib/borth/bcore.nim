import pkg/core
import pkg/lib/print
import ./runtime
import ./words

const
  Lt = sym"lt"
  Gt = sym"gt"
  Eq = sym"eq"

template numeric(body) {.dirty.} =
  binary a, b:
    if not allKind({bNum}, a, b):
      refuse "requires 2 numbers"
    lifted:
      body

wordSet installCore:
  ## numeric ================

  word "add":
    numeric:
      rt.push num(a.num + b.num)

  word "sub":
    numeric:
      rt.push num(a.num - b.num)

  word "mul":
    numeric:
      rt.push num(a.num * b.num)

  word "div":
    numeric:
      if b.num == 0:
        refuse "division by zero"
      rt.push num(a.num div b.num)

  ## recognition ================

  word "cmp":
    binary a, b:
      let c = cmp(a, b)
      rt.push (if c < 0: Lt elif c == 0: Eq else: Gt)

  word "num-cmp":
    ## numeric order between two numbers with a symbol
    ## result. This is because CE order isn't numeric
    ## order. Since based on CE ordering -5 > 5
    ## This is bounded by the machine range currently,
    ## and refuses on overflow!
    binary a, b:
      if not allKind({bNum}, a, b):
        refuse "requires 2 numbers"
      let c = cmp(a.asInt, b.asInt)
      rt.push (if c < 0: Lt elif c == 0: Eq else: Gt)

  word "kind":
    unary a:
      rt.push sym(
        case a.kind
        of bNil: "nil"
        of bNum: "num"
        of bText: "text"
        of bSym: "sym"
        of bBytes: "bytes"
        of bList: "list"
        of bRecord: "record"
        of bDict: "dict"
        of bSet: "set"
      )

  word "mark":
    unary a:
      rt.push a.mark(true)

  word "unmark":
    unary a:
      rt.push a.mark(false)

  ## collections ================

  word "at":
    binary val, key:
      if val.isKind(bSet):
        refuse "sets answer has?, not at"
      lifted:
        rt.push val.at(key)

  word "has?":
    binary coll, k:
      let present =
        case coll.kind
        of bDict: coll.hasKey(k)
        of bSet, bList, bRecord: coll.contains(k)
        else: refuse "not a frame"
      rt.push sym(if present: "present" else: "absent")

  word "len":
    unary a:
      case a.kind
      of bList, bRecord, bSet:
        rt.push num(a.contents.len)
      of bDict:
        rt.push num(pairsLen(a))
      else:
        refuse "not a frame"

  word "keys":
    unary a:
      lifted:
        # a cast changes the reading; the declaration does not travel
        rt.push mark(open(a).keys.seal, false)

  word "vals":
    unary a:
      lifted:
        rt.push mark(open(a).vals().close(), false)

  word "->dict":
    unary a:
      if not a.isKind(bList):
        refuse "needs a list"
      lifted:
        var b = open(a)
        b.rekind(bDict)
        b.marked = false
        rt.push close b

  word "merge":
    binary a, b:
      lifted:
        rt.push close merge(open(a), open(b))

  word "put":
    let v = rt.pop
    let k = rt.pop
    let coll = rt.pop
    lifted:
      rt.push close put(open(coll), k, v)

  word "difference":
    binary a, b:
      lifted:
        rt.push seal difference(open(a), open(b))

  word "fry":
    unary temp:
      lifted:
        let n = fryReach(temp)
        if n > rt.height:
          refuse "the template reaches " & $n & " deep; the stack holds " &
            $rt.height
        rt.charge n
        let r = fry(temp, rt.stack.toOpenArray(rt.height - n, rt.height - 1))
        rt.stack.setLen(rt.height - n)
        rt.push r

  ## stack manipulation ================

  word "dup":
    unary a:
      rt.push a, a

  word "drop":
    discard rt.pop()

  word "swap":
    binary a, b:
      rt.push b, a

  word "take":
    unary amount:
      let n = amount.asInt
      if n < 0:
        refuse "negative amount"
      if n > rt.height:
        refuse "amount > stack height"
      var items = newSeq[Value](n)
      for i in countdown(n - 1, 0):
        items[i] = rt.pop()
      rt.push list(items)

  word "stack-height":
    rt.push num(rt.height)

  ## definitions ================

  word "define":
    binary quote, name:
      if not quote.isKind(bList):
        refuse "quote must be a list"
      if name.marked:
        refuse "name must not be marked"
      rt.define(name.mark(true), quoteWord(quote))

  word "macro":
    binary quote, name:
      if not quote.isKind(bList):
        refuse "quote must be a list"
      rt.defineMacro(name, quoteWord(quote))

  word "var":
    unary name:
      if name.marked:
        refuse "name must not be marked"
      if rt.isDefined(name.mark(true)):
        return
      rt.define(name.mark(true), cellWord())

  word "set":
    binary val, name:
      let key = name.mark(true)
      if not rt.isDefined(key):
        refuse "no cell named " & $name
      if rt.words[key].kind != wCell:
        refuse $name & " is not a cell"
      if rt.words[key].protected:
        refuse $name & " is protected"
      rt.words[key].value = val

  word "read":
    unary name:
      let key = name.mark(true)
      if not rt.isDefined(key):
        refuse "no cell named " & $name
      if rt.words[key].kind != wCell:
        refuse $name & " is not a cell"
      rt.push rt.words[key].value

  word "words":
    var installed: seq[Value] = @[]
    for k in rt.words.keys:
      installed.add k
    rt.push set(installed)

  word "binding":
    unary name:
      rt.push rt.bindingOf(name)

  word "annotate":
    binary name, patch:
      rt.annotate(name, patch)

  word "dictionary":
    rt.push rt.dictionaryOf()

  ## evaluation ================

  word "do":
    rt.doQuote(rt.pop())

  word "dip":
    binary x, quote:
      rt.doDip(x, quote)

  word "each":
    binary coll, quote:
      rt.doEach(coll, quote)

  word "map":
    binary coll, quote:
      rt.doMap(coll, quote)

  ## io ================

  word "read-value":
    rt.push rt.readValue()

  word "read-until":
    unary stop:
      if stop.marked:
        refuse "stop cannot be marked"
      var items: seq[Value] = @[]
      while true:
        rt.charge()
        let v = rt.readValue()
        if v == stop:
          break
        else:
          items.add v
      rt.push list(items)

  word "echo":
    echo rt.pop