import std/[unittest, tables, sets]
import blnim/values
import blnim/misc/hash

suite "smoke tests":
  test "basic insertion & updates for tables":
    let
      greeting = sym"hello world!"
      other = sym"hello again!"
    var someTable = {nilValue(): greeting}.toTable

    check someTable[nilValue()] == greeting

    someTable[nilValue(true)] = other

    check someTable[nilValue()] == greeting
    check someTable[nilValue(true)] == other

    someTable[nilValue(true)] = num"123"

    check someTable[nilValue(true)] == num"123"

  test "basic insertion & updates for sets":
    let
      greeting = sym"hello world!"
      other = sym"hello again!"
    var
      a = toHashSet([greeting])
      b = toHashSet([other])
      c = a + b

    check a.contains(greeting)
    check b.contains(other)

    check c.contains(greeting)
    check c.contains(other)
