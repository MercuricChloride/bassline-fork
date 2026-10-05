import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import {
  cmp,
  encode,
  fromJson,
  JsonError,
  jsonToValue,
  numberReviver,
  readDocument,
  readValue,
  toJson,
  value,
  valueToJson,
  type JsonNode,
  type Value,
} from '../src/index.ts'
import { randValue } from './random.ts'

const dir = new URL('../../../corpus/', import.meta.url)
const cases = readDocument(
  value,
  readFileSync(new URL('corpus.bl', dir), 'utf8')
)
const corpusJson = readFileSync(new URL('corpus.json', dir), 'utf8')

const same = (a: Value, b: Value) => {
  expect(encode(a)).toEqual(encode(b))
  expect(cmp(a, b)).toBe(0)
}

/** The node with every dict's and set's members in reverse. */
function reversed(n: JsonNode): JsonNode {
  const v = n.value
  if (!Array.isArray(v)) return n
  const each = (x: unknown): unknown =>
    Array.isArray(x)
      ? x.map(y => reversed(y as JsonNode))
      : reversed(x as JsonNode)
  const members = v.map(each)
  return {
    ...n,
    value: n.kind === 'dict' || n.kind === 'set' ? members.reverse() : members,
  }
}

function refusal(f: () => unknown) {
  try {
    f()
  } catch (e) {
    return e
  }
  throw new Error('not refused')
}

describe('corpus', () => {
  it('corpus.json reads as the cases corpus.bl holds', () => {
    const nodes = JSON.parse(corpusJson, numberReviver as never) as unknown[]
    expect(nodes.length).toBe(cases.length)
    nodes.forEach((n, i) => same(jsonToValue(value, n), cases[i]!))
  })

  it('the cases write as corpus.json, byte for byte', () => {
    expect(JSON.stringify(cases.map(valueToJson), null, 2) + '\n').toBe(
      corpusJson
    )
  })

  it('reads dict and set members in any order', () => {
    for (const c of cases) {
      same(jsonToValue(value, reversed(valueToJson(c))), c)
    }
  })
})

describe('round trips', () => {
  it('random values write and read back as themselves', () => {
    for (let n = 0; n < 300; n++) {
      const v = randValue(3)
      const s = toJson(v)
      same(fromJson(value, s), v)
      expect(toJson(fromJson(value, s))).toBe(s)
    }
  })

  it('keeps an integer past 2^53 a JSON number, digit for digit', () => {
    const wide = 10n ** 30n + 7n
    const s = toJson(value.number(wide))
    expect(s).toBe('{"kind":"number","value":1000000000000000000000000000007}')
    expect((fromJson(value, s) as Value<'number'>).payload).toBe(wide)
    expect(toJson(value.number(-(2n ** 63n)))).toContain('-9223372036854775808')
  })

  it('writes the mark only when set, and bytes in lower-case hex', () => {
    expect(toJson(readValue(value, '[go! 0xDEAD]'))).toBe(
      '{"kind":"list","value":[{"kind":"symbol","mark":true,"value":"go"},' +
        '{"kind":"bytes","value":"0xdead"}]}'
    )
    expect(toJson(readValue(value, '!{a: nil}'))).toBe(
      '{"kind":"dict","mark":true,"value":[[{"kind":"symbol","value":"a"},{"kind":"nil"}]]}'
    )
  })

  it('reads through whatever factory it is given', () => {
    const made: string[] = []
    const spy = {
      ...value,
      sym: (s: string, mark = false) => (made.push(s), value.sym(s, mark)),
    }
    fromJson(spy, toJson(readValue(value, '(f a {b c})')))
    expect(made).toEqual(['f', 'a', 'b', 'c'])
  })
})

describe('refusals', () => {
  const bad: Record<string, string> = {
    'not an object': '5',
    'an array, not a value': '[1, 2]',
    'no kind': '{"value": 1}',
    'kind is not a string': '{"kind": 1}',
    'unknown kind': '{"kind": "blob", "value": 1}',
    'a kind from the prototype': '{"kind": "toString", "value": []}',
    'unknown key': '{"kind": "nil", "colour": "red"}',
    'mark is not a boolean': '{"kind": "nil", "mark": 1}',
    'nil carries a value': '{"kind": "nil", "value": null}',
    'missing value': '{"kind": "text"}',
    'number is a float': '{"kind": "number", "value": 1.5}',
    'number is -0': '{"kind": "number", "value": -0}',
    'number in exponent form': '{"kind": "number", "value": 1e3}',
    'number as a string': '{"kind": "number", "value": "1"}',
    'text is not a string': '{"kind": "text", "value": 5}',
    'text with a lone surrogate': '{"kind": "text", "value": "\\ud800"}',
    'bytes without 0x': '{"kind": "bytes", "value": "dead"}',
    'bytes with an odd hex count': '{"kind": "bytes", "value": "0xabc"}',
    'bytes with a non-hex digit': '{"kind": "bytes", "value": "0xzz"}',
    'record with no head': '{"kind": "record", "value": []}',
    'list members not an array': '{"kind": "list", "value": 5}',
    'dict entry not a pair': '{"kind": "dict", "value": [[{"kind":"nil"}]]}',
    'duplicate dict key':
      '{"kind":"dict","value":[[{"kind":"nil"},{"kind":"nil"}],[{"kind":"nil"},{"kind":"nil"}]]}',
    'duplicate set member':
      '{"kind":"set","value":[{"kind":"nil"},{"kind":"nil"}]}',
    'not JSON at all': '{kind: nil}',
  }

  it.each(Object.entries(bad))('refuses %s', (_name, src) => {
    expect(refusal(() => fromJson(value, src))).toBeInstanceOf(JsonError)
  })

  it('refuses an integer that already lost its digits', () => {
    const lost = { kind: 'number', value: Number.MAX_SAFE_INTEGER + 2 }
    expect(() => jsonToValue(value, lost)).toThrow(JsonError)
  })

  it('refuses nesting past the depth limit', () => {
    let n: unknown = { kind: 'nil' }
    for (let i = 0; i < 9; i++) n = { kind: 'list', value: [n] }
    expect(jsonToValue(value, n, { maxDepth: 9 }).kind).toBe('list')
    expect(() => jsonToValue(value, n, { maxDepth: 8 })).toThrow(JsonError)
  })
})
