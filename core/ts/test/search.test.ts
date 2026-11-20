import { describe, expect, it } from 'vitest'
import {
  answer,
  answers,
  encode,
  isObject,
  objects,
  orders,
  print,
  pull,
  question,
  readValue,
  Scope,
  Search,
  SearchError,
  Refused,
  searches,
  value,
  type Value,
} from '../src/index.ts'

const o = objects()
const { cat, alt, feed, searchOver, fromValue } = searches()

const read = (t: string) => readValue(value, t)
const space = (t: string) => read(t) as Value<'set' | 'dict'>
const hex = (v: Value) => Buffer.from(encode(v)).toString('hex')
const same = (a: Iterable<Value>, b: string[]) =>
  expect([...a].map(hex)).toEqual(b.map(t => hex(read(t))))
const said = (v: Value) => print(v)

describe('objects', () => {
  const note = read(
    '!{!(kind note) (identity n1) (identity 0x01) (text "hi") (text "ho")}'
  )

  it('is a marked set', () => {
    expect(isObject(note)).toBe(true)
    expect(isObject(read('{(text "hi")}'))).toBe(false)
  })

  it('answers what its unmarked records say, in CE order', () => {
    same(answers(note, read('text')), ['"hi"', '"ho"'])
    expect(said(answer(note, read('text'))!)).toBe('"hi"')
    expect(answer(note, read('title'))).toBeUndefined()
  })

  it('orders are its marked records, kinds among them', () => {
    same(orders(note, read('kind')), ['note'])
    same(o.kinds(note), ['note'])
    expect(o.hasKind(note, read('note'))).toBe(true)
    expect(o.hasKind(note, read('text'))).toBe(false)
  })

  it('passes over records of another width', () => {
    same(answers(read('!{(text) (text "a" "b") (text "c")}'), read('text')), [
      '"c"',
    ])
  })

  it('a value that is not an object answers nothing', () => {
    same(answers(read('{(text "hi")}'), read('text')), [])
  })

  it('goes by every name it answers to identity', () => {
    same(o.identities(note), ['n1', '0x01'])
    same(o.identities(read('n1')), ['n1'])
    expect(o.knownAs(note, read('0x01'))).toBe(true)
    expect(o.knownAs(read('n1'), read('n1'))).toBe(true)
    expect(o.sharesIdentity(read('!{(identity n1)}'), note)).toBe(true)
    expect(o.sharesIdentity(read('n2'), note)).toBe(false)
  })

  it('writes names, kinds and more', () => {
    expect(
      said(o.identity(read('a'), read('!{(identity b) (identity c)}')))
    ).toBe(said(read('!{(identity a) (identity b) (identity c)}')))
    expect(said(o.identityOf(note))).toBe(
      said(read('!{(identity n1) (identity 0x01)}'))
    )
    expect(said(o.alsoKnownAs(note, read('n2')))).toBe(
      said(
        read(
          '!{!(kind note) (identity n1) (identity n2) (identity 0x01) (text "hi") (text "ho")}'
        )
      )
    )
    expect(
      said(o.describe([read('a'), read('b')], read('x'), read('(title "t")')))
    ).toBe(said(read('!{!(kind a) !(kind b) (identity x) (title "t")}')))
  })

  it('makes random identities of sixteen bytes', () => {
    const [a, b] = [o.randomId(), o.randomId()]
    const name = [...o.identities(a)][0]!
    expect(name.kind).toBe('bytes')
    expect(name.length).toBe(16)
    expect(o.sharesIdentity(a, b)).toBe(false)
  })
})

describe('searches', () => {
  const people = space('{(alice 1) (alice 2) (bob 3) (alice) (carol 4 5)}')

  it('over a set answers the records under the query, passing over questions', () => {
    const s = searchOver(people, read('s1'))
    same(s.ask(read('alice')), ['1', '2'])
    same(s.ask(read('dave')), [])
    expect(() => [...s.ask(read('carol'))]).toThrow(SearchError)
    same(searchOver(people, read('s1'), v => v, true).ask(read('carol')), [])
  })

  it('over a dict answers its one entry', () => {
    const s = searchOver(space('{alice: 1 bob: 2}'), read('d'))
    same(s.ask(read('bob')), ['2'])
    same(s.ask(read('carol')), [])
  })

  it('reads answers back through `read`, skipping refusals when asked to', () => {
    const num = (v: Value) => {
      if (v.kind !== 'number') throw new Refused('not a number')
      return v.payload
    }
    const s = searchOver(space('{(a 1) (a x) (a 2)}'), read('s'), num, true)
    expect([...s.ask(read('a'))]).toEqual([1, 2])
    expect(() => [
      ...searchOver(space('{(a x)}'), read('s'), num).ask(read('a')),
    ]).toThrow(Refused)
    const broken = (v: Value): number =>
      (v as unknown as { no: { such: number } }).no.such
    expect(() => [
      ...searchOver(space('{(a 1)}'), read('s'), broken, true).ask(read('a')),
    ]).toThrow(TypeError)
  })

  it('refuses a marked space, as reading one back does', () => {
    expect(() => searchOver(space('!{(q 1)}'), read('s'))).toThrow(SearchError)
  })

  it('composes: cat in turn, alt taking turns, feed asking on', () => {
    const a = searchOver(space('{(q 1) (q 2) (q 3)}'), read('a'))
    const b = searchOver(space('{(q 10) (q 20)}'), read('b'))
    same(cat([a, b]).ask(read('q')), ['1', '2', '3', '10', '20'])
    same(alt([a, b]).ask(read('q')), ['1', '10', '2', '20', '3'])
    const first = searchOver(space('{(who alice) (who bob)}'), read('f'))
    const then = searchOver(space('{(alice 1) (alice 2) (bob 3)}'), read('t'))
    // bob sorts before alice: shortlex
    same(feed(first, then).ask(read('who')), ['3', '1', '2'])
  })

  it('a function is a search with no denotation', () => {
    const s = cat([(q: Value) => [q, q]])
    same(s.ask(read('x')), ['x', 'x'])
    expect(s.denotable).toBe(false)
    expect(() => s.toValue()).toThrow(SearchError)
    expect(said(s.id()).length).toBeGreaterThan(0)
  })

  it('pulls nothing ahead', () => {
    let asked = 0
    const s = new Search<Value, Value>(function* (q) {
      asked++
      yield q
    })
    const st = cat([s, s]).ask(read('x'))
    expect(asked).toBe(0)
    pull(st)
    expect(asked).toBe(1)
  })

  it('writes itself down, and reads back as the same search', () => {
    const a = searchOver(space('{(q 1) (q 2)}'), read('a'))
    const b = searchOver(space('{q: 3}'), read('b'))
    const c = cat([a, b], read('c'))
    expect(said(c.toValue())).toBe(
      said(
        read(
          '!{!(kind search-space) !(kind cat) (identity c) (parts [!{!(kind search-space) (identity a) (holds {(q 1) (q 2)})} !{!(kind search-space) (identity b) (holds {q: 3})}])}'
        )
      )
    )
    const back = fromValue(c.toValue())
    same(back.ask(read('q')), ['1', '2', '3'])
    expect(said(back.toValue())).toBe(said(c.toValue()))
    expect(said(back.id())).toBe(said(read('!{(identity c)}')))
  })

  it('reads several holds in turn, and an alt and a feed', () => {
    same(
      fromValue(
        read(
          '!{!(kind search-space) (identity s) (holds {(q 1)}) (holds {(q 2)})}'
        )
      ).ask(read('q')),
      ['1', '2']
    )
    const d = read(
      '!{!(kind search-space) !(kind alt) (identity s) (parts [!{!(kind search-space) (identity a) (holds {(q 1) (q 2)})} !{!(kind search-space) (identity b) (holds {(q 3)})}])}'
    )
    same(fromValue(d).ask(read('q')), ['1', '3', '2'])
  })

  it('resolves names when asked, passing over a name met again', () => {
    const known = searchOver(
      space(`{
      (a !{!(kind search-space) (identity a) (holds {(q 1)})})
      (loop !{!(kind search-space) !(kind cat) (identity loop) (parts [!{(identity loop)} !{!(kind search-space) (identity x) (holds {(q 9)})}])})
    }`),
      read('known')
    )
    const d = read(
      '!{!(kind search-space) !(kind cat) (identity c) (parts [!{(identity a)} !{(identity nowhere)}])}'
    )
    same(fromValue(d, { resolve: known }).ask(read('q')), ['1'])
    same(
      fromValue(read('!{(identity loop)}'), { resolve: known }).ask(read('q')),
      ['9']
    )
    expect(() => fromValue(d)).toThrow(SearchError)
  })

  it('refuses what it cannot read', () => {
    for (const t of [
      '!{!(kind search-space) (identity s)}',
      '!{!(kind search-space) !(kind ranked) (identity s) (holds {(q 0 a)})}',
      '!{!(kind search-space) !(kind cat) !(kind alt) (identity s) (parts [])}',
      '!{!(kind note) (identity s)}',
      '!{!(kind search-space) (identity s) (holds [(q 1)])}',
    ])
      expect(() => fromValue(read(t)), t).toThrow(SearchError)
  })
})

describe('scopes', () => {
  const showing = question<string, string>('showing')
  const saying = question<string, string>('saying')
  const forever = (tag: string) =>
    function* () {
      for (let i = 0; ; i++) yield tag + i
    }

  it('asks nearest first, then takes turns, and never asks another question', () => {
    const app = new Scope({ name: 'app' })
      .put(showing, q => [q + ':app'])
      .put(saying, () => ['no'])
    const nb = new Scope({ parent: app, name: 'notebook' })
      .put(showing, forever('a'))
      .put(showing, q => [q + ':nb1', q + ':nb2'])
    expect(nb.ask(showing, 'x').take(7).toArray()).toEqual([
      'a0',
      'x:nb1',
      'x:app',
      'a1',
      'x:nb2',
      'a2',
      'a3',
    ])
    expect(nb.first(showing, 'x')).toBe('a0')
    expect(app.ask(showing, 'x').toArray()).toEqual(['x:app'])
  })

  it('asks nothing ahead of a pull, and sees what is put before it gets there', () => {
    let asked = 0
    const app = new Scope()
    const nb = new Scope({ parent: app }).put(showing, q => {
      asked++
      return [q]
    })
    const answers = nb.ask(showing, 'x')
    expect(asked).toBe(0)
    app.put(showing, () => ['late'])
    expect(answers.toArray()).toEqual(['x', 'late'])
    expect(asked).toBe(1)
  })

  it('reaches nearer scopes first, each when a question gets there', () => {
    let walked = 0
    const near = new Scope().put(showing, () => ['near'])
    const app = new Scope().put(showing, () => ['app'])
    const s = new Scope({
      parent: app,
      nearer: function* () {
        walked++
        yield near
      },
    }).put(showing, () => ['own'])
    expect(walked).toBe(0)
    expect(s.ask(showing, 'x').toArray()).toEqual(['near', 'own', 'app'])
    expect([...s.reach(showing)].map(r => [r.out, r.index])).toEqual([
      [0, 0],
      [1, 0],
      [2, 0],
    ])
  })

  it('replays who answers, each with its first answer', () => {
    const app = new Scope({ name: 'app' }).put(showing, () => ['app'])
    const nb = new Scope({ parent: app, name: 'nb' })
      .put(showing, () => [])
      .put(showing, forever('n'))
    expect(
      [...nb.replay(showing, 'x')].map(([r, a]) => [r.scope.name, r.index, a])
    ).toEqual([
      ['nb', 1, 'n0'],
      ['app', 0, 'app'],
    ])
  })

  it('hands a question on as one search, and takes searches out', () => {
    const s = new Scope()
    const one = new Search<string, string>(() => ['one'])
    s.put(showing, one).put(showing, () => ['two'])
    const asked = s.search(showing)
    expect(asked.ask('x').toArray()).toEqual(['one', 'two'])
    s.remove(showing, one)
    expect(asked.ask('x').toArray()).toEqual(['two'])
  })
})
