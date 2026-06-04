import { msg, is, word } from '@bassline/core'

export class Observation extends CustomEvent {
  constructor(bassline, type, detail) {
    super(type, { detail })
    this.bassline = bassline
  }
}

export class Bassline {
  events = new EventTarget()
  controller = new AbortController()
  signal = this.controller.signal

  ids = new WeakMap()
  items = new Map()
  locations = new Map()
  fns = Object.create(null)

  is = { ...is }

  identify(value) {
    if (!is.object(value) && !is.fn(value)) return undefined
    if (!this.ids.has(value)) this.ids.set(value, crypto.randomUUID())
    return this.ids.get(value)
  }

  track(value, { kind, note } = {}) {
    const id = this.identify(value)
    if (id && !this.items.has(id)) {
      this.items.set(id, { id, value, kind, note })
      this.emit('track', { id, value, kind, note })
    }
    return value
  }

  keep(name, value) {
    this.locations.set(name, value)
    this.track(value, { kind: 'location', note: name })
    this.emit('keep', { name, value })
    return value
  }

  fn(name, fn) {
    if (this.fns[name]) {
      this.emit('fn-removed', { name, fn: this.fns[name] })
    }
    this.fns[name] = fn
    this.track(fn, { kind: 'fn', note: name })
    this.emit('fn-installed', { name, fn })
    return this
  }

  use(installer, ...args) {
    installer(this, ...args)
    return this
  }

  on(type, fn, opts = { signal: this.signal }) {
    this.events.addEventListener(type, fn, opts)
    return () => this.off(type, fn, opts)
  }

  off(type, fn, opts) {
    this.events.removeEventListener(type, fn, opts)
    return this
  }

  emit(type, detail) {
    this.events.dispatchEvent(new Observation(this, type, detail))
    return this
  }

  msg = desc => this.track(msg(desc), { kind: 'msg' })
  word = def => this.track(word(def), { kind: 'word' })
  noun = v => this.word({ noun: v })
  verb = fn => this.word({ verb: fn })
}
