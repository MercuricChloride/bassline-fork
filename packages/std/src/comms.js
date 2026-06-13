// [[file:../../../book.org::*Lifecycle Controller][Lifecycle Controller:1]]
export class UseAfterClose extends Error {
  constructor(aController) {
    super('attempted to use a controller after it has been closed')
    this.controller = aController
  }
}

export class Controller {
  controller = new AbortController()
  get signal() {
    return this.controller.signal
  }
  get closed() {
    return this.signal.aborted
  }
  assertOpen() {
    if (this.closed) throw new UseAfterClose(this)
  }
  close(reason = 'closed') {
    if (!this.closed) this.controller.abort(reason)
  }
  onClose(fn, { signal } = {}) {
    if (this.closed) fn()
    else this.signal.addEventListener('abort', fn, { once: true, signal })
    return this
  }
}
// Lifecycle Controller:1 ends here

// [[file:../../../book.org::*Port implementation][Port implementation:1]]
export function derivePort(bl) {
  const { is, word } = bl.reference
  class Port extends Controller {
    buffer = []
    waiters = []
    get isBounded() {
      return this.size !== Infinity
    }
    get anyWaiting() {
      return this.waiters.length > 0
    }
    get overflowing() {
      return this.buffer.length >= this.size
    }
    get shouldBuffer() {
      return this.size > 0
    }
    constructor(size = Infinity) {
      super()
      this.size = size
      this.onClose(() => {
        for (const waiter of this.waiters) waiter(undefined)
        this.waiters.length = 0
      })
    }
    async recv() {
      if (this.buffer.length > 0) return this.buffer.shift()
      if (this.closed) return undefined
      return new Promise(resolve => this.waiters.push(resolve))
    }
    send(aMsg) {
      if (is.undefined(aMsg) || this.closed) return
      if (this.anyWaiting) return this.waiters.shift()(aMsg)
      if (this.overflowing) this.buffer.shift()
      if (this.shouldBuffer) this.buffer.push(aMsg)
    }
    async consume(aWord) {
      while (true) {
        const aMsg = await this.recv()
        if (is.undefined(aMsg)) break
        aWord.verb(aMsg)
      }
    }
    asWord() {
      return word({
        noun: {
          size: this.isBounded ? this.size : null,
          bounded: this.isBounded,
        },
        verb: aMsg => this.send(aMsg),
      })
    }
  }
  const port = size => new Port(size)
  return { port, Port }
}

// Port implementation:1 ends here

// [[file:../../../book.org::*Propagator][Propagator:1]]
export function derivePropagator(bl) {
  const { is, verb } = bl.reference
  class Propagator {
    constructor(fn = (aMsg, send) => send(aMsg)) {
      this.targets = new Set()
      this.fn = fn
    }
    target(...words) {
      for (const aWord of words) {
        if (!is.word(aWord)) throw new Error(`expected word: ${aWord}`)
        if (!is.vbound(aWord)) throw new Error(`expected vbound word: ${aWord}`)
        this.targets.add(aWord)
      }
      return () => {
        for (const aWord of words) this.targets.delete(aWord)
      }
    }
    emit(aMsg) {
      for (const w of this.targets) w.verb(aMsg)
    }
    send(aMsg) {
      this.fn(aMsg, v => this.emit(v))
    }
    asWord() {
      return verb(aMsg => this.send(aMsg))
    }
  }
  const propagator = fn => new Propagator(fn)
  const map = aFn =>
    propagator((aMsg, send) => {
      const result = aFn(aMsg)
      if (is.msg(result)) send(result)
    })
  const filter = predicate =>
    propagator((aMsg, send) => {
      if (predicate(aMsg)) send(aMsg)
    })
  return { Propagator, propagator, map, filter }
}
// Propagator:1 ends here

export default function (bl) {
  return { ...derivePort(bl), ...derivePropagator(bl) }
}
