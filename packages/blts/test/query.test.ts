import { describe, expect, it } from 'vitest'
import {
  encode,
  finds,
  objects,
  print,
  readValue,
  Search,
  SearchError,
  searches,
  value,
  type Value,
} from '../src/index.ts'

const { find, evaluate, findSearch, readFind } = finds()
const { fromValue, search } = searches()
const o = objects()

const read = (t: string) => readValue(value, t)
const reads = (...ts: string[]) => ts.map(read)
const hex = (v: Value) => Buffer.from(encode(v)).toString('hex')
const same = (a: Iterable<Value>, b: string[]) =>
  expect([...a].map(hex)).toEqual(b.map(t => hex(read(t))))
const sameSet = (a: Iterable<Value>, b: string[]) =>
  expect([...a].map(hex).sort()).toEqual(b.map(t => hex(read(t))).sort())

const repo = read(`!{!(kind search-space) (identity repo) (holds {
  ("a" dir) ("a" (has "a/x")) ("a" (has "a/y"))
  ("a/x" file) ("a/x" (about "the x file")) ("a/x" (in "a"))
  ("a/y" file) ("a/y" (about "the y file")) ("a/y" (in "a"))
  ((mentions x) "a/x") (help "ask a path") (odd !(within z))
})}`)

/** Finds names among `known`, by their identities. */
const among =
  (...known: Value[]) =>
  (names: Value) =>
    known.filter(k => o.sharesIdentity(k, names))

const f_ids = (v: Value) => [...o.identities(v)][0]!

const answers = (
  q: Value,
  asked?: Value,
  resolve?: (n: Value) => Iterable<Value | Search<Value, Value>>
) =>
  evaluate(q, {
    ...(asked === undefined ? {} : { asked }),
    ...(resolve === undefined ? {} : { resolve }),
  }).map(r => r.answer)

describe('finds', () => {
  it('answers what a space answers to a question', () => {
    const q = find({
      of: [repo],
      holes: reads('a'),
      wheres: reads('(help a)'),
      gives: reads('a'),
    })
    same(answers(q), ['"ask a path"'])
  })

  it('feeds bindings from clause to clause, sharing holes', () => {
    const q = find({
      of: [repo],
      holes: reads('p', 't'),
      wheres: reads('((mentions x) p)', '(p (about t))'),
      gives: reads('(p t)'),
    })
    same(answers(q), ['("a/x" "the x file")'])
  })

  it('gives the bindings when it says no gives', () => {
    const q = find({
      of: [repo],
      holes: reads('p', 't'),
      wheres: reads('((mentions x) p)', '(p (about t))'),
    })
    same(answers(q), ['{p: "a/x" t: "the x file"}'])
  })

  it('looks at every record for a clause whose question is not settled', () => {
    const q = find({
      of: [repo],
      holes: reads('p'),
      wheres: reads('(p (in "a"))'),
      gives: reads('p'),
    })
    sameSet(answers(q), ['"a/x"', '"a/y"'])
  })

  it('answers each binding once, written each way it gives', () => {
    const q = find({
      of: [repo],
      holes: reads('p'),
      wheres: reads('((mentions x) p)'),
      gives: reads('(path p)', '(seen p)'),
    })
    same(answers(q), ['(path "a/x")', '(seen "a/x")'])
  })

  it('distinct answers each answer once', () => {
    const q = (kinds: 'distinct'[]) =>
      find({
        of: [repo],
        holes: reads('p', 'x'),
        wheres: reads('(p x)'),
        gives: reads('kind'),
        kinds,
      })
    expect([...answers(q([]))].length).toBe(11) // a hole fits its own mark: (odd !(within z)) is passed over
    same(answers(q(['distinct'])), ['kind'])
  })

  it('counts as it finds, never a total', () => {
    const q = find({
      of: [repo],
      holes: reads('p'),
      wheres: reads('(p file)'),
      gives: reads('p'),
      kinds: ['count'],
    })
    same(answers(q), ['1', '2'])
  })

  it('says why: the parts whose records answered', () => {
    const q = find({
      of: [repo],
      holes: reads('a'),
      wheres: reads('(help a)'),
      gives: reads('a'),
      kinds: ['why'],
    })
    same(answers(q), ['(why "ask a path" {!{(identity repo)}})'])
    const [row] = evaluate(
      find({
        of: [repo],
        holes: reads('a'),
        wheres: reads('(help a)'),
        gives: reads('a'),
      })
    )
    same(
      [row!.why[0]!.clause, row!.why[0]!.from],
      ['(help a)', '!{(identity repo)}']
    )
  })
})

describe('forms', () => {
  it('within fits anything with the part anywhere in it, the whole record bound by all', () => {
    const q = find({
      of: [repo],
      holes: reads('r'),
      wheres: reads('!(all r !(within "a/x"))'),
      gives: reads('r'),
    })
    sameSet(answers(q), [
      '("a" (has "a/x"))',
      '("a/x" file)',
      '("a/x" (about "the x file"))',
      '("a/x" (in "a"))',
      '((mentions x) "a/x")',
    ])
  })

  it('within inside a pattern looks deep in an answer', () => {
    const q = find({
      of: [repo],
      holes: reads('p'),
      wheres: reads('(p !(within "a"))'),
      gives: reads('p'),
    })
    sameSet(answers(q), ['"a/x"', '"a/y"'])
  })

  it('within binds holes wherever its part fits', () => {
    const q = find({
      of: [repo],
      holes: reads('d'),
      wheres: reads('("a/x" !(within (in d)))'),
      gives: reads('d'),
    })
    same(answers(q), ['"a"'])
  })

  it('any fits what fits one of its parts', () => {
    const q = find({
      of: [repo],
      holes: reads('p'),
      wheres: reads('(p !(any file dir))'),
      gives: reads('p'),
    })
    sameSet(answers(q), ['"a"', '"a/x"', '"a/y"'])
  })

  it('as binds a hole to what fits, whatever its mark', () => {
    const q = find({
      of: [repo],
      holes: reads('h', 'a'),
      wheres: reads('(h !(as a))'),
      gives: reads('a'),
      kinds: ['distinct'],
    })
    expect([...answers(q)].map(hex)).toContain(hex(read('!(within z)')))
    const r = find({
      of: [repo],
      holes: reads('r'),
      wheres: reads('!(as r (help))'),
      gives: reads('r'),
    })
    same(answers(r), ['(help "ask a path")'])
    const bound = (w: string) =>
      find({
        of: [repo],
        holes: reads('p'),
        wheres: reads('((mentions x) !(as p))', w),
      })
    same(answers(bound('(p file)')), ['{p: "a/x"}'])
    same(answers(bound('("a/y" !(as p))')), [])
    for (const w of ['!(as)', '!(as nothole)', '!(as h a b)'])
      expect(() =>
        readFind(find({ of: [repo], holes: reads('h'), wheres: [read(w)] }))
      ).toThrow(SearchError)
  })

  it('quote is the value as written', () => {
    const q = find({
      of: [repo],
      holes: reads('h'),
      wheres: reads('(h !(quote !(within z)))'),
      gives: reads('h'),
    })
    same(answers(q), ['odd'])
  })

  it('a quoted question is settled, and asked as what it quotes', () => {
    const base = read(
      '!{!(kind search-space) (identity base) (holds {(q yes)})}'
    )
    const inner = find(
      {
        of: [base],
        holes: reads('a', 'h'),
        asked: reads('h'),
        wheres: reads('(h a)'),
        gives: reads('a'),
      },
      read('inner')
    )
    same(
      answers(
        find({
          of: [inner],
          holes: reads('a'),
          wheres: reads('(!(quote q) a)'),
          gives: reads('a'),
        })
      ),
      ['yes']
    )
    same(
      answers(
        find({
          of: [inner],
          holes: reads('a', 'h'),
          wheres: reads('(!(as h q) a)'),
          gives: reads('[h a]'),
        })
      ),
      ['[q yes]']
    )
    same(
      answers(
        find({
          of: [inner],
          holes: reads('a', 'h'),
          wheres: reads('(!(all h q) a)'),
          gives: reads('[h a]'),
        })
      ),
      ['[q yes]']
    )
    // a form fitting one record asks that record's question: !(as r) once r is bound
    const both =
      read(`!{!(kind search-space) !(kind alt) (identity both2) (parts [
      !{!(kind search-space) (holds {(bind (q yes))})} ${print(inner)}])}`)
    same(
      answers(
        find({
          of: [both],
          holes: reads('r'),
          wheres: reads('(bind r)', '!(as r)'),
          gives: reads('r'),
        })
      ),
      ['(q yes)']
    )
    // !(any …) asks each alternative's question, when each has one
    same(
      answers(
        find({
          of: [inner],
          wheres: reads('!(any (q yes))'),
          gives: reads('ok'),
        })
      ),
      ['ok']
    )
    same(
      answers(
        find({
          of: [inner],
          holes: reads('a'),
          wheres: reads('!(any (q a) (nope a))'),
          gives: reads('a'),
        })
      ),
      ['yes']
    )
    // an alternative no record fits asks nothing, and needs no scan
    same(
      answers(
        find({
          of: [inner],
          wheres: reads('!(any nope (q yes))'),
          gives: reads('ok'),
        })
      ),
      ['ok']
    )
    // a head that is a form asks every head it can be
    same(
      answers(
        find({
          of: [inner],
          wheres: reads('(!(any nope q) yes)'),
          gives: reads('ok'),
        })
      ),
      ['ok']
    )
    same(
      answers(
        find({
          of: [inner],
          wheres: reads('(!(any q) yes)'),
          gives: reads('ok'),
        })
      ),
      ['ok']
    )
  })

  it('a head that is a list or record fits any it begins, as in shapes; a set or dict any it covers', () => {
    const s = read(`!{!(kind search-space) (identity s) (holds {
      ((tag extra) yes) ([tag extra] list) ({tag extra} set) ({k: 1 more: 2} dict) ((other) no)
    })}`)
    const ask = (head: string) =>
      answers(
        find({
          of: [s],
          holes: reads('v'),
          wheres: [read(`(${head} v)`)],
          gives: reads('v'),
        })
      )
    same(ask('(tag)'), ['yes'])
    same(ask('[tag]'), ['list'])
    same(ask('{tag}'), ['set'])
    same(ask('{k: 1}'), ['dict'])
    // a bound hole or a quote is exactly one head
    same(ask('!(quote (tag))'), [])
    same(
      answers(
        find({
          of: [s],
          holes: reads('h', 'v'),
          asked: reads('h'),
          wheres: reads('(h v)'),
          gives: reads('v'),
        }),
        read('(tag)')
      ),
      []
    )
  })

  it('a scan of a ranked space comes in rank order, as do several questions of one', () => {
    const s = read(
      '!{!(kind search-space) !(kind ranked) (identity s) (holds {(a 9 aa) (b 0 bb)})}'
    )
    same(
      answers(
        find({
          of: [s],
          holes: reads('h', 'x'),
          wheres: reads('(h x)'),
          gives: reads('[h x]'),
        })
      ),
      ['[b bb]', '[a aa]']
    )
    same(
      answers(
        find({
          of: [s],
          holes: reads('x'),
          wheres: reads('!(any (a x) (b x))'),
          gives: reads('x'),
        })
      ),
      ['bb', 'aa']
    )
  })

  it('a hole under a quote is no hole, and counts for nothing in choosing a clause', () => {
    const s = read(
      '!{!(kind search-space) (identity s) (holds {(a [a1 z]) (a [a2 z]) (b b1) (b b2)})}'
    )
    same(
      answers(
        find({
          of: [s],
          holes: reads('x', 'y', 'z'),
          wheres: reads('(a [y !(quote z)])', '(b x)'),
          gives: reads('[x y]'),
        })
      ),
      ['[b1 a1]', '[b2 a1]', '[b1 a2]', '[b2 a2]']
    )
  })

  it('a hole is a hole, whatever is inside it', () => {
    const t = read('!{!(kind search-space) (identity t) (holds {(q b) (r a)})}')
    same(
      answers(
        find({
          of: [t],
          holes: reads('(q x)'),
          wheres: reads('(q x)'),
          gives: reads('(q x)'),
        })
      ),
      ['(q b)', '(r a)']
    )
    const s = read('!{!(kind search-space) (identity s) (holds {(q yes)})}')
    same(
      answers(
        find({
          of: [s],
          holes: reads('{!(within)}'),
          wheres: reads('(q {!(within)})'),
          gives: reads('{!(within)}'),
        })
      ),
      ['yes']
    )
    // a hole, not within: marked, it fits only a marked record, and the space holds none
    same(
      answers(
        find({
          of: [s],
          holes: reads('!(within q)'),
          wheres: reads('!(within q)'),
          gives: reads('!(within q)'),
        })
      ),
      []
    )
  })

  it('refuses a form without what it needs', () => {
    for (const w of [
      '!(within)',
      '!(within a b)',
      '!(quote)',
      '!(any)',
      '!(all)',
    ])
      expect(() => readFind(find({ of: [repo], wheres: [read(w)] }))).toThrow(
        SearchError
      )
  })
})

describe('reading a find', () => {
  it('refuses a kind it does not read, an asked that is no hole, and count with why', () => {
    expect(() =>
      readFind(read('!{!(kind search-space) !(kind find) !(kind cat)}'))
    ).toThrow(SearchError)
    expect(() =>
      readFind(read('!{!(kind search-space) !(kind find) (asked d)}'))
    ).toThrow(SearchError)
    expect(() =>
      readFind(
        read('!{!(kind search-space) !(kind find) !(kind count) !(kind why)}')
      )
    ).toThrow(SearchError)
    expect(() => readFind(read('!{!(kind search-space) (holds {})}'))).toThrow(
      SearchError
    )
  })

  it('reads its parts back as written', () => {
    const fd = readFind(
      read(
        '!{!(kind search-space) !(kind find) !(kind distinct) (of s) (hole p) (asked p) (where (p x)) (gives p)}'
      )
    )
    same(fd.of, ['s'])
    same(fd.holes.children(), ['p'])
    same(fd.asked, ['p'])
    same(fd.wheres, ['(p x)'])
    same(fd.gives, ['p'])
    expect([fd.distinct, fd.count, fd.why]).toEqual([true, false, false])
  })
})

describe('subjects', () => {
  const room =
    read(`!{!(kind search-space) !(kind ranked) (identity room) (holds {
    (general 1 !{!(kind message) (by bob) (said "yo")})
    (general 0 !{!(kind message) (by alice) (said "hi")})
    (general 2 !{!(kind message) (by alice) (said "again")})
  })}`)

  it('a ranked space answers in rank order, its rank passed over or bound', () => {
    const q = find({
      of: [room],
      holes: reads('b', 's'),
      wheres: reads('(general !{(by b) (said s)})'),
      gives: reads('(b s)'),
    })
    same(answers(q), ['(alice "hi")', '(bob "yo")', '(alice "again")'])
    const r = find({
      of: [room],
      holes: reads('r'),
      wheres: reads('(general r !{(by bob)})'),
      gives: reads('r'),
    })
    same(answers(r), ['1'])
  })

  it('an object answers its own records', () => {
    const note = read('!{!(kind note) (identity n1) (text "hi") (style quote)}')
    const q = find({
      of: [note],
      holes: reads('t'),
      wheres: reads('(text t)'),
      gives: reads('t'),
    })
    same(answers(q), ['"hi"'])
    const k = find({
      of: [note],
      holes: reads('k'),
      wheres: reads('!(kind k)'),
      gives: reads('k'),
    })
    same(answers(k), ['note'])
    // a record of another width is no answer
    const odd = read('!{!(kind note) (identity s) (q a b)}')
    same(
      answers(
        find({
          of: [odd],
          holes: reads('x', 'y'),
          wheres: reads('(q x y)'),
          gives: reads('[x y]'),
        })
      ),
      []
    )
  })

  it('a hole bound whatever its mark fits what it is bound to when met again', () => {
    const s = read(
      '!{!(kind search-space) (identity s) (holds {(a yes) (z yes)})}'
    )
    same(
      answers(
        find({
          of: [s],
          holes: reads('h!'),
          wheres: reads('(a !(as h!))', '(z h!)'),
          gives: reads('h!'),
        })
      ),
      ['yes']
    )
  })

  it('names are found when asked, through what the asker hands in', () => {
    const q = find({
      of: reads('repo'),
      holes: reads('a'),
      wheres: reads('(help a)'),
      gives: reads('a'),
    })
    same(answers(q, undefined, among(repo)), ['"ask a path"'])
    expect(() => [...answers(q)]).toThrow(SearchError)
  })

  it('a subject is read as fromValue reads a space, refusals passed over only when asked', () => {
    const ask = (space: string, skipRefused = false) =>
      evaluate(
        find({
          of: [read(space)],
          holes: reads('x'),
          wheres: reads('(n x)'),
          gives: reads('x'),
        }),
        { skipRefused }
      ).map(r => r.answer)
    expect(() => [
      ...ask('!{!(kind search-space) !(kind frob) (holds {(n 1)})}'),
    ]).toThrow(SearchError)
    expect(() => [
      ...ask('!{!(kind search-space) !(kind cat) !(kind alt) (parts [])}'),
    ]).toThrow(SearchError)
    expect(() => [
      ...ask('!{!(kind search-space) !(kind merge) (parts [])}'),
    ]).toThrow(SearchError)
    expect(() => [...ask('!{!(kind search-space) (holds [(n 1)])}')]).toThrow(
      SearchError
    )
    expect(() => [
      ...ask('!{!(kind search-space) (holds {(n 1) (n 2 3)})}'),
    ]).toThrow(SearchError)
    same(ask('!{!(kind search-space) (holds {(n 1) (n 2 3)})}', true), ['1'])
    same(ask('!{!(kind search-space) (holds {(n 1) (n)})}'), ['1'])
    // a composite's parts are ranked as it is, and are searches
    expect(() => [
      ...ask(
        '!{!(kind search-space) !(kind cat) (parts [!{!(kind search-space) !(kind ranked) (holds {(n 0 a)})}])}'
      ),
    ]).toThrow('a ranked space, read as unranked')
    expect(() => [
      ...ask(
        '!{!(kind search-space) !(kind cat) (parts [!{!(kind note) (n 1)}])}'
      ),
    ]).toThrow(SearchError)
    same(
      ask(
        '!{!(kind search-space) !(kind ranked) !(kind merge) (parts [!{!(kind search-space) !(kind ranked) (holds {(n 0 a)})}])}'
      ),
      ['a']
    )
    // a feed: each answer of the first asked of the second, ranked as the second
    same(
      ask(
        '!{!(kind search-space) !(kind feed) !(kind ranked) (parts [!{!(kind search-space) (holds {(n mid)})} !{!(kind search-space) !(kind ranked) (holds {(mid 0 a)})}])}'
      ),
      ['a']
    )
    same(
      ask(
        '!{!(kind search-space) !(kind feed) (parts [!{!(kind search-space) (holds {(n mid)})} !{!(kind search-space) (holds {(mid a) (mid b)})}])}'
      ),
      ['a', 'b']
    )
    expect(() => [
      ...ask(
        '!{!(kind search-space) !(kind feed) (parts [!{!(kind search-space) (holds {(n mid)})}])}'
      ),
    ]).toThrow(SearchError)
    // several lists of parts: each joined, and then the lists
    same(
      ask(
        '!{!(kind search-space) !(kind alt) (parts [!{!(kind search-space) (holds {(n a)})} !{!(kind search-space) (holds {(n b)})}]) (parts [!{!(kind search-space) (holds {(n c)})}])}'
      ),
      ['a', 'c', 'b']
    )
  })

  it('a rank is a natural of any size', () => {
    const room = read(
      '!{!(kind search-space) !(kind ranked) (identity room) (holds {(q 9223372036854775808 yes)})}'
    )
    same(
      answers(
        find({
          of: [room],
          holes: reads('x'),
          wheres: reads('(q x)'),
          gives: reads('x'),
        })
      ),
      ['yes']
    )
  })

  it('a hole or form taking a ranked record takes it as held, rank and all', () => {
    const room = read(
      '!{!(kind search-space) !(kind ranked) (identity room) (holds {(general 0 "hi") (general 1 "hi") (q 7 yes)})}'
    )
    same(
      answers(
        find({
          of: [room],
          holes: reads('r'),
          wheres: reads('!(all r (general "hi"))'),
          gives: reads('r'),
        })
      ),
      ['(general 0 "hi")', '(general 1 "hi")']
    )
    same(
      answers(
        find({
          of: [room],
          holes: reads('w'),
          wheres: reads('!(as w (q 7 yes))'),
          gives: reads('w'),
        })
      ),
      ['(q 7 yes)']
    )
  })

  it('says why once for each set of parts that answers', () => {
    const one = read('!{!(kind search-space) (identity one) (holds {(n 1)})}')
    const two = read('!{!(kind search-space) (identity two) (holds {(n 1)})}')
    const q = find({
      of: [one, two],
      holes: reads('x'),
      wheres: reads('(n x)'),
      gives: reads('x'),
      kinds: ['why'],
    })
    sameSet(answers(q), [
      '(why 1 {!{(identity one)}})',
      '(why 1 {!{(identity two)}})',
    ])
  })

  it('says why for a clause that only checks, once for each part', () => {
    const one = read(
      '!{!(kind search-space) (identity one) (holds {(ready yes)})}'
    )
    const two = read(
      '!{!(kind search-space) (identity two) (holds {(ready yes)})}'
    )
    const q = find({
      of: [one, two],
      wheres: reads('(ready yes)'),
      gives: reads('ok'),
      kinds: ['why'],
    })
    sameSet(answers(q), [
      '(why ok {!{(identity one)}})',
      '(why ok {!{(identity two)}})',
    ])
  })

  it('what each binding leads to takes turns, so an endless subject starves none', () => {
    const live = search<Value, Value>(function* (q) {
      if (print(q) === 'n') yield* reads('1', '2')
      if (print(q) === '1') for (let i = 0; ; i++) yield read(`(more ${i})`)
      if (print(q) === '2') yield read('two')
    })
    const q = find({
      of: reads('live'),
      holes: reads('x', 'y'),
      wheres: reads('(n x)', '(x y)'),
      gives: reads('(x y)'),
    })
    const first = answers(q, undefined, n =>
      print(n) === 'live' ? [live] : []
    )
      .take(10)
      .toArray()
    expect(first.map(print)).toContain('(2 two)')
  })

  it('a gives is written only where the bindings bind every hole in it', () => {
    const q = find({
      of: [repo],
      holes: reads('p', 'f'),
      wheres: reads('(p !(any (has f) file))'),
      gives: reads('(p f)'),
    })
    sameSet(answers(q), ['("a" "a/x")', '("a" "a/y")'])
  })

  it('a search running here is asked as it is, and can only be asked what is settled', () => {
    const live = search<Value, Value>(function* (q) {
      if (print(q) === 'views') yield* reads('table', 'board')
    })
    const q = find({
      of: reads('app'),
      holes: reads('v'),
      wheres: reads('(views v)'),
      gives: reads('v'),
    })
    same(
      answers(q, undefined, n => (print(n) === 'app' ? [live] : [])),
      ['table', 'board']
    )
    const open = find({
      of: reads('app'),
      holes: reads('x', 'v'),
      wheres: reads('(x v)'),
      gives: reads('v'),
    })
    same(
      answers(open, undefined, n => (print(n) === 'app' ? [live] : [])),
      []
    )
  })

  it('several subjects take turns, and composites join their parts', () => {
    const one = read(
      '!{!(kind search-space) (identity one) (holds {(n 1) (n 2)})}'
    )
    const two = read(
      '!{!(kind search-space) (identity two) (holds {(n 10) (n 20)})}'
    )
    const q = (of: Value[]) =>
      find({ of, holes: reads('x'), wheres: reads('(n x)'), gives: reads('x') })
    same(answers(q([one, two])), ['1', '10', '2', '20'])
    const cat = read(
      '!{!(kind search-space) !(kind cat) (identity both) (parts [one two])}'
    )
    same(answers(q([cat]), undefined, among(one, two)), ['1', '2', '10', '20'])
  })

  it('names that lead round to themselves come to an end', () => {
    const loop = read(
      '!{!(kind search-space) !(kind cat) (identity loop) (parts [loop repo])}'
    )
    const q = find({
      of: reads('loop'),
      holes: reads('a'),
      wheres: reads('(help a)'),
      gives: reads('a'),
    })
    same(answers(q, undefined, among(loop, repo)), ['"ask a path"'])
  })

  it('so do names that lead round through a find', () => {
    const self = find(
      {
        of: reads('loop2'),
        holes: reads('a'),
        wheres: reads('(help a)'),
        gives: reads('a'),
      },
      read('self')
    )
    const loop = read(
      '!{!(kind search-space) !(kind alt) (identity loop2) (parts [self repo])}'
    )
    same(answers(self, undefined, among(self, loop, repo)), ['"ask a path"'])
    same(
      fromValue(self, {
        resolve: search<Value, Value>(n => among(self, loop, repo)(n)),
      }).ask(read('nil')),
      ['"ask a path"']
    )
  })
})

describe('a find as a search', () => {
  const listing = find(
    {
      of: [read('repo')],
      holes: reads('d', 'f', 't'),
      asked: reads('d'),
      wheres: reads('(d (has f))', '(f (about t))'),
      gives: reads('(f t)'),
    },
    read('listing')
  )

  it('binds what it is asked to its asked holes', () => {
    same(findSearch(listing, among(repo)).ask(read('"a"')), [
      '("a/x" "the x file")',
      '("a/y" "the y file")',
    ])
  })

  it('reads back through fromValue, and composes like any space', () => {
    const resolve = search<Value, Value>(n => among(repo, listing)(n))
    same(fromValue(listing, { resolve }).ask(read('"a"')), [
      '("a/x" "the x file")',
      '("a/y" "the y file")',
    ])
    const both = read(
      '!{!(kind search-space) !(kind alt) (identity both) (parts [repo listing])}'
    )
    sameSet(fromValue(both, { resolve }).ask(read('"a"')), [
      'dir',
      '(has "a/x")',
      '(has "a/y")',
      '("a/x" "the x file")',
      '("a/y" "the y file")',
    ])
    expect(hex(fromValue(listing, { resolve }).toValue())).toBe(hex(listing))
  })

  it('is a subject another find asks', () => {
    const q = find({
      of: [listing],
      holes: reads('e'),
      wheres: reads('("a" e)'),
      gives: reads('e'),
    })
    same(answers(q, undefined, among(repo)), [
      '("a/x" "the x file")',
      '("a/y" "the y file")',
    ])
  })

  it('a find within a gives keeps its own holes whole, an outer hole inside one too', () => {
    const s = read('!{!(kind search-space) (identity s) (holds {(r o)})}')
    const inner = read(
      '!{!(kind search-space) !(kind find) (identity i) (hole [x]) (where ([x] v)) (gives [x])}'
    )
    const q = find({
      of: [s],
      holes: reads('x'),
      wheres: reads('(r x)'),
      gives: [inner],
    })
    same(answers(q), [
      '!{!(kind search-space) !(kind find) (identity i) (hole [x]) (where ([x] v)) (gives [x]) (of ' +
        print(s) +
        ')}',
    ])
  })

  it('a gives can carry a find, its own holes kept and the subjects named', () => {
    const inner = find(
      { holes: reads('f'), wheres: reads('(d (has f))'), gives: reads('f') },
      read('inner')
    )
    const q = find({
      of: [repo],
      holes: reads('d'),
      wheres: reads('(d dir)'),
      gives: [
        value.dict([
          [read('dir'), read('d')],
          [read('files'), inner],
        ]),
      ],
    })
    const [answer] = answers(q)
    const nested = (answer as Value<'dict'>).get(read('files'))!
    same(readFind(nested).wheres, ['("a" (has f))'])
    same(readFind(nested).of, [print(repo)])
    same(o.identities(nested), ['[inner {d: "a"}]'])
    // a name with a hole in it is filled, and still goes with every binding used
    const two = read(
      '!{!(kind search-space) (identity two) (holds {(bind [same 1]) (bind [same 2])})}'
    )
    sameSet(
      answers(
        find({
          of: [two],
          holes: reads('x', 'y'),
          wheres: reads('(bind [x y])'),
          gives: [
            read(
              '!{!(kind search-space) !(kind find) (identity x) (of nil) (where (q y))}'
            ),
          ],
        })
      ).map(a => f_ids(a)),
      ['[same {x: same y: 1}]', '[same {x: same y: 2}]']
    )
    same(answers(nested), ['"a/x"', '"a/y"'])
  })
})

describe('more: a search asked again of its answers', () => {
  const tree = read(`!{!(kind search-space) (identity tree) (holds {
    (root (has a)) (a (has b)) (a (has b2)) (b (has c)) (c (has a))
  })}`)
  const down = find(
    {
      of: reads('tree'),
      holes: reads('d', 'f'),
      asked: reads('d'),
      wheres: reads('(d (has f))'),
      gives: reads('f'),
    },
    read('down')
  )
  const resolve = search<Value, Value>(n => among(tree, down)(n))

  it('nearest first, each once, and a walk that comes round again ends', () => {
    const walk = read(
      '!{!(kind search-space) !(kind more) (identity walk) (parts [down])}'
    )
    const s = fromValue(walk, { resolve })
    same(s.ask(read('root')), ['a', 'b', 'b2', 'c'])
    expect(hex(s.toValue())).toBe(hex(walk))
  })

  it('via answers the way each answer was reached', () => {
    const walk = read(
      '!{!(kind search-space) !(kind more) !(kind via) (identity walk) (parts [down])}'
    )
    same(fromValue(walk, { resolve }).ask(read('root')), [
      '(via [root] a)',
      '(via [root a] b)',
      '(via [root a] b2)',
      '(via [root a b] c)',
    ])
  })

  it('a step is any search, a find of two clauses among them', () => {
    const board = read(`!{!(kind search-space) (identity board) (holds {
      (p1 (on top)) (p1 (shows inner)) (p2 (on inner)) (p2 (shows note))
    })}`)
    const inside = find(
      {
        of: reads('board'),
        holes: reads('b', 'p', 't'),
        asked: reads('b'),
        wheres: reads('(p (on b))', '(p (shows t))'),
        gives: reads('t'),
      },
      read('inside')
    )
    const walk = read(
      '!{!(kind search-space) !(kind more) (identity walk) (parts [inside])}'
    )
    same(
      fromValue(walk, {
        resolve: search<Value, Value>(n => among(board, inside)(n)),
      }).ask(read('top')),
      ['inner', 'note']
    )
    same(
      searches()
        .more(findSearch(inside, among(board)))
        .ask(read('top')),
      ['inner', 'note']
    )
  })

  it('a more is a subject a find can ask', () => {
    const walk = read(
      '!{!(kind search-space) !(kind more) (identity walk) (parts [down])}'
    )
    const q = find({
      of: [walk],
      holes: reads('x'),
      wheres: reads('(root x)'),
      gives: reads('x'),
    })
    same(answers(q, undefined, among(tree, down)), ['a', 'b', 'b2', 'c'])
  })

  it('refuses via without more, and a more of other than one part', () => {
    expect(() =>
      fromValue(
        read('!{!(kind search-space) !(kind cat) !(kind via) (parts [down])}'),
        { resolve }
      )
    ).toThrow(SearchError)
    expect(() =>
      fromValue(
        read('!{!(kind search-space) !(kind more) (parts [down down])}'),
        { resolve }
      )
    ).toThrow(SearchError)
  })
})
