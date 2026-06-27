import { describe, expect, it } from 'vitest'
import {
  barfBackward,
  barfForward,
  slurpBackward,
  slurpForward,
  type Edit,
} from '../src/paredit'

type Op = (text: string, offset: number) => Edit | null

/** `|` marks the cursor. Returns the resulting text, or null. */
function run(op: Op, marked: string): string | null {
  const offset = marked.indexOf('|')
  const text = marked.slice(0, offset) + marked.slice(offset + 1)
  return op(text, offset)?.text ?? null
}

describe('slurpForward', () => {
  it('engulfs the next sibling into a list', () => {
    expect(run(slurpForward, '[a|] b')).toBe('[a b]')
    expect(run(slurpForward, '[a|]b')).toBe('[a b]')
  })
  it('works at the top level', () => {
    expect(run(slurpForward, '[a|] b c')).toBe('[a b] c')
  })
  it('engulfs into an empty frame without a leading space', () => {
    expect(run(slurpForward, '[|] b')).toBe('[b]')
  })
  it('engulfs into a record', () => {
    expect(run(slurpForward, '(f|) x')).toBe('(f x)')
  })
  it('treats a dict value/key as an ordinary sibling', () => {
    expect(run(slurpForward, '{a|: 1} b')).toBe('{a: 1 b}')
  })
  it('keeps the actionable mark with the opener', () => {
    expect(run(slurpForward, '`[a|] b')).toBe('`[a b]')
  })
  it('is a no-op with no next sibling', () => {
    expect(run(slurpForward, '[a|]')).toBeNull()
  })
  it('is a no-op when the cursor is outside any frame', () => {
    expect(run(slurpForward, '[a] |b')).toBeNull()
  })
})

describe('barfForward', () => {
  it('expels the last child of a list', () => {
    expect(run(barfForward, '[a b|]')).toBe('[a] b')
  })
  it('expels the only child', () => {
    expect(run(barfForward, '[a|]')).toBe('[] a')
  })
  it('expels a dict value as an ordinary form', () => {
    expect(run(barfForward, '{a: 1|}')).toBe('{a:} 1')
  })
})

describe('slurpBackward', () => {
  it('engulfs the previous sibling', () => {
    expect(run(slurpBackward, 'x [a|]')).toBe('[x a]')
  })
  it('engulfs into an empty frame', () => {
    expect(run(slurpBackward, 'x [|]')).toBe('[x]')
  })
  it('keeps the actionable mark with the opener', () => {
    expect(run(slurpBackward, 'a `[b|]')).toBe('`[a b]')
  })
  it('is a no-op with no previous sibling', () => {
    expect(run(slurpBackward, '[a|]')).toBeNull()
  })
})

describe('barfBackward', () => {
  it('expels the first child of a list', () => {
    expect(run(barfBackward, '[a| b]')).toBe('a [b]')
  })
  it('expels the only child', () => {
    expect(run(barfBackward, '[a|]')).toBe('a []')
  })
})

describe('strings and symbols are atomic forms', () => {
  it('slurps a string as a whole, preserving its inner spaces', () => {
    expect(run(slurpForward, '[a|] "x y"')).toBe('[a "x y"]')
  })
  it('slurps a quoted symbol as a whole', () => {
    expect(run(slurpForward, "[a|] 'b c'")).toBe("[a 'b c']")
  })
  it('barfs a string as a whole', () => {
    expect(run(barfForward, '[a "x y"|]')).toBe('[a] "x y"')
  })
  it('is not confused by a colon inside a dict string value', () => {
    expect(run(slurpForward, '{a|: "x:y"} z')).toBe('{a: "x:y" z}')
  })
})
