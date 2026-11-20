import bassline

refuseWith BasslineError

type
  Bindings* = ref object of Live
    bindings: seq[Binding]
  Binding* = ref object of Live
    bound: bool
    key, val: Value

method reified*(self: Binding): Value =
  let (k,v) = (self.key.toNode, self.val.toNode)
  toValue bl"($k $v)"

proc maybeBind*(self: Binding, val: sink Value) =
  if self.key != val: return
  if self.bound:
    guard self.val == val, "binding mismatch"
  else:
    self.val = val
    self.bound = true

proc newBinding*(key: sink Value): Binding =
  Binding(key: key)

proc setBindings(self: var Value): bool {.discardable.} =
  if self.kind != bSet: return
  var changed: bool
  for each in self.members(changed):
    each = newBinding(each.toValue).toNode
    changed = true
  changed

proc main =
  var
    something = bl"(a (b c) {foo: bar})"
    bindings = bl"{a b}"

  echo something[1][0]
  echo something[2][bl"foo"]

  bindings.asValue.setBindings

  for each in bindings.asValue.members:
    echo each

main()
