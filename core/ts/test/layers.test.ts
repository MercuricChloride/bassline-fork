import { describe, expect, it } from 'vitest'
import {
  attach,
  attachAll,
  attachLayer,
  binder,
  bl,
  carried,
  declare,
  eq,
  encode,
  fresh,
  HIGH,
  Layer,
  layersOf,
  LOW,
  moldsOf,
  readAll,
  reader,
  readings,
  value,
  type Value,
} from '../src/index.ts'

// a dialect: (task NAME TEXT), said alone or as a message's field
class Task extends Layer {
  readonly name: string
  readonly text: string
  constructor(name: string, text: string) {
    super()
    this.name = name
    this.text = text
  }
  override mold() {
    return value.record([
      value.sym('task'),
      value.sym(this.name),
      value.text(this.text),
    ])
  }
}
class Urgent extends Task {}
const fieldOf = (v: Value, head: string) => {
  if (v.kind === 'record')
    return v.items[0]?.kind === 'symbol' && v.items[0].payload === head
      ? v
      : undefined
  if (v.kind === 'set')
    for (const m of v.children())
      if (
        m.kind === 'record' &&
        m.items[0]?.kind === 'symbol' &&
        m.items[0].payload === head
      )
        return m
  return undefined
}
reader(
  Task,
  v => {
    const r = fieldOf(v, 'task')
    if (r?.kind !== 'record' || r.items.length < 3) return undefined
    const [, n, t] = r.items
    return n?.kind === 'symbol' && t?.kind === 'text'
      ? new Task(n.payload, t.payload)
      : undefined
  },
  { head: 'task' }
)
reader(
  Urgent,
  v => (fieldOf(v, 'urgent') ? new Urgent('?', 'urgent') : undefined),
  { head: 'urgent', priority: HIGH }
)

// a runtime-only kind with no reader, only a binder
class Seen extends Layer {
  readonly at: number
  constructor(at: number) {
    super()
    this.at = at
  }
}
binder(Seen, (_l, v) => v.kind === 'set')

// a kind kept private
class Secret extends Layer {}
declare(Secret, { private: true })
reader(Secret, () => new Secret(), { priority: LOW })

describe('layers', () => {
  it('reads a layer from a value once and keeps it on that node', () => {
    const v = bl`(task parser "fix the frame rule")`
    const t = attach(v, Task)!
    expect(t).toBeInstanceOf(Task)
    expect(t.name).toBe('parser')
    expect(attach(v, Task)).toBe(t)
    expect(layersOf(v)).toEqual([t])
  })

  it('keeps layers per node, never in bytes or equality', () => {
    const a = bl`(task parser "x")`
    const b = bl`(task parser "x")`
    attach(a, Task)
    expect(carried(a, Task)).toBeDefined()
    expect(carried(b, Task)).toBeUndefined()
    expect(eq(a, b)).toBe(true)
    expect(encode(a)).toEqual(encode(b))
    expect(layersOf(fresh(a))).toEqual([])
  })

  it('asks a reader with a head only of values led by it, records or objects', () => {
    expect(attach(bl`(claim parser)`, Task)).toBeUndefined()
    const msg = bl`!{(by goose) (task csv "write the door") (said "please")}`
    expect(attach(msg, Task)?.name).toBe('csv')
  })

  it('reads a kind through the readers of kinds inheriting from it', () => {
    const v = bl`!{(urgent yes)}`
    expect(attach(v, Task)).toBeInstanceOf(Urgent)
    expect(carried(v, Urgent)).toBeDefined()
  })

  it('gives every reading in priority order without attaching', () => {
    const v = bl`!{(task a "one") (urgent yes)}`
    const rs = [...readings(v)]
    expect(rs.map(r => r.constructor)).toEqual([Urgent, Task])
    expect(layersOf(v)).toEqual([])
  })

  it('keeps private kinds out of readings unless named', () => {
    const v = bl`hello`
    expect([...readings(v)].some(l => l instanceof Secret)).toBe(false)
    expect([...readings(v, [Secret])][0]).toBeInstanceOf(Secret)
    expect(readAll(v).some(l => l instanceof Secret)).toBe(false)
  })

  it('puts a layer made apart on a value when a binder takes it', () => {
    const s = new Seen(5)
    expect(attachLayer(bl`[1 2]`, s)).toBe(false)
    const v = bl`{1 2}`
    expect(attachLayer(v, s)).toBe(true)
    expect(carried(v, Seen)).toBe(s)
  })

  it('reads all and gives the molds as a set', () => {
    const v = bl`!{(task a "one")}`
    readAll(v)
    expect(eq(moldsOf(v), bl`{(task a "one")}`)).toBe(true)
  })

  it('attaches through a whole value', () => {
    const v = bl`[(task a "one") [(task b "two")]]`
    attachAll(v, Task)
    const inner = (v as Value<'list'>).items[1] as Value<'list'>
    expect(carried(inner.items[0]!, Task)?.name).toBe('b')
  })

  it('remembers a value no reader reads as a kind, until a reader is added', () => {
    class Late extends Layer {}
    const v = bl`(late 1)`
    expect(attach(v, Late)).toBeUndefined()
    reader(Late, () => new Late(), { head: 'late' })
    expect(attach(v, Late)).toBeInstanceOf(Late)
  })
})
