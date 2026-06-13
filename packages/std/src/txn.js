const MSG = Symbol.for('$$IS_MSG$$')
const CAP = Symbol.for('$$IS_CAP$$')

class Msg {
  data = {}
  caps = {}
  get [MSG]() {
    return true
  }
}

/**
@typedef {(msg: Msg) => void} Handler
 */

// A place is a locally addressable location that can be sent messages
// A place recognizes caps, which are unique handles to itself
// When sending a message, we can optionally include the cap in which
// we are invoking with
// If it is absent, it's considered a "top level" send

class Place {
  send(_aMsg, _aCap = null) {
    throw new Error('must implement send(aMsg, aCap?)')
  }
}

class Link {}

class Cap {
  get [CAP]() {
    return true
  }
}

class Link {
  constructor(place) {
    this.place = place
  }
  send(aMsg, aCap) {
    this.place.send(aMsg, aCap)
  }
}

const m = new Msg()

console.log(m)

function isMsg(aMsg) {
  return aMsg?.[MSG] === true
}

console.log(isMsg(m))
console.log(isMsg(123))

const bar = new Cap()

console.log(foo instanceof Cap)
console.log(bar instanceof Cap)
