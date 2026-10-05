// Random values of every kind, with marks, wide integers, payloads across the
// length tiers and awkward text.

import { value, type Value } from '../src/index.ts'

const int = (n: number) => Math.floor(Math.random() * n)
const pick = <T>(xs: T[]) => xs[int(xs.length)]!

const awkward = [
  '',
  'a',
  '\u00E9',
  'e\u0301',
  '\uFEFFbom',
  '\u{1F600}',
  '\uFFFF',
  '\uE000',
  '\u{10000}',
  '\u{10FFFF}',
  '\u0000',
  'nil',
  'a b',
  '\n\t',
]

/** A length that lands near a tier edge as often as not. */
function len() {
  return pick([0, 1, 6, 7, 8, 254, 255, 256, int(10), int(300)])
}

function text() {
  if (Math.random() < 0.5) return pick(awkward)
  let s = ''
  const n = len()
  while (s.length < n) s += pick(awkward) || 'x'
  return s
}

function integer(): number | bigint {
  switch (int(5)) {
    case 0:
      return pick([0, 1, -1, 9, 10, -10])
    case 1:
      return int(2 ** 31) - 2 ** 30
    case 2:
      return pick([Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER])
    case 3:
      return (
        BigInt(int(2 ** 53)) *
        BigInt(int(2 ** 53)) *
        (Math.random() < 0.5 ? -1n : 1n)
      )
    default: {
      let s = String(1 + int(9))
      for (let i = int(300); i > 0; i--) s += int(10)
      return BigInt((Math.random() < 0.5 ? '-' : '') + s)
    }
  }
}

export function randValue(depth = 3): Value {
  const mark = Math.random() < 0.25
  const kinds = depth > 0 ? 9 : 5
  const many = (f: () => Value) => Array.from({ length: int(5) }, f)
  const sub = () => randValue(depth - 1)
  switch (int(kinds)) {
    case 0:
      return value.nil(mark)
    case 1:
      return value.number(integer(), mark)
    case 2:
      return value.text(text(), mark)
    case 3:
      return value.sym(text(), mark)
    case 4:
      return value.bytes(
        Uint8Array.from({ length: len() }, () => int(256)),
        mark
      )
    case 5:
      return value.list(many(sub), mark)
    case 6:
      return value.record([sub(), ...many(sub)], mark)
    case 7:
      return value.dict(
        many(sub).map(k => [k, sub()] as [Value, Value]),
        mark
      )
    default:
      return value.set(many(sub), mark)
  }
}
