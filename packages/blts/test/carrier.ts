// The kind-tagged JSON carrier, enough to read corpus.json before blts has
// a reader. Dict and set members are inserted shuffled, so the collections
// have to put them in order themselves.

import { value, type Value } from '../src/index.ts'

type Carried = { kind: string; mark?: boolean; value?: unknown }

/** JSON.parse that keeps every integer exact, however wide. */
export function parseJson(src: string): unknown {
  return JSON.parse(src, ((
    _key: string,
    v: unknown,
    ctx?: { source?: string }
  ) =>
    typeof v === 'number' &&
    ctx?.source !== undefined &&
    !Number.isSafeInteger(v)
      ? BigInt(ctx.source)
      : v) as (key: string, v: unknown) => unknown)
}

export function shuffled<T>(xs: T[]): T[] {
  const out = [...xs]
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[out[i], out[j]] = [out[j]!, out[i]!]
  }
  return out
}

function hex(s: string) {
  if (!s.startsWith('0x')) throw new TypeError('bytes without 0x: ' + s)
  const out = new Uint8Array((s.length - 2) / 2)
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(s.slice(2 + 2 * i, 4 + 2 * i), 16)
  }
  return out
}

export function fromCarrier(j: unknown): Value {
  const { kind, mark = false, value: v } = j as Carried
  switch (kind) {
    case 'nil':
      return value.nil(mark)
    case 'number':
      return value.number(v as number | bigint, mark)
    case 'text':
      return value.text(v as string, mark)
    case 'symbol':
      return value.sym(v as string, mark)
    case 'bytes':
      return value.bytes(hex(v as string), mark)
    case 'list':
      return value.list((v as unknown[]).map(fromCarrier), mark)
    case 'record':
      return value.record((v as unknown[]).map(fromCarrier), mark)
    case 'set':
      return value.set(shuffled((v as unknown[]).map(fromCarrier)), mark)
    case 'dict':
      return value.dict(
        shuffled(
          (v as [unknown, unknown][]).map(
            ([k, x]) => [fromCarrier(k), fromCarrier(x)] as [Value, Value]
          )
        ),
        mark
      )
  }
  throw new TypeError('unknown kind ' + kind)
}
