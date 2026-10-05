// The JSON carrier: a value as kind-tagged JSON, and back. JSON is a foreign
// format: it only carries values, it is never canonical (a value's only
// identity is its CE bytes), and reading refuses what it cannot hold rather
// than coercing it.
//
// Each value is an object { "kind": KIND, "mark"?: true, "value": … }:
//
//   nil        no "value"
//   number     a JSON number spelled in digits, at any width
//   text       a JSON string
//   symbol     a JSON string
//   bytes      a "0x…" hex string
//   list       an array of values
//   record     an array of values, head first, at least one
//   dict       an array of [key, value] pairs
//   set        an array of values
//
// Dict and set members are read in any order and written in canonical order.
// A duplicate, an unknown key on the object, and a number that is not an
// integer spelling are refused.

import { MAX_DEPTH } from '../codec/util.ts'
import { steps } from '../ops.ts'
import {
  spelling,
  TAGS,
  type Atom,
  type Factory,
  type Frame,
  type Value,
  type ValueKind,
} from '../types.ts'

/** JSON that is not a reading of a value. */
export class JsonError extends Error {}

/** A value in the carrier, as plain JSON data. */
export type JsonNode = { kind: ValueKind; mark?: true; value?: unknown }

export type JsonOptions = {
  /** How deep frames may nest. */
  maxDepth?: number
}

const CANONICAL_INT = /^(0|-?[1-9][0-9]*)$/

function need(cond: boolean, msg: string): asserts cond {
  if (!cond) throw new JsonError(msg)
}

/** Some JSON data, for a refusal to name. */
function show(x: unknown): string {
  try {
    return JSON.stringify(x) ?? typeof x
  } catch {
    return typeof x
  }
}

// JSON.rawJSON and JSON.isRawJSON (Node 21 and later) are not in TypeScript's
// lib yet
const { rawJSON, isRawJSON } = JSON as unknown as {
  rawJSON(text: string): unknown
  isRawJSON(x: unknown): x is { rawJSON: string }
}

// ================ reading ================

/**
 * The reviver `fromJson` hands to `JSON.parse`. It reads every JSON number
 * from the parser's source, so none is rounded: a number where it is a safe
 * integer, a bigint past that, and a refusal for anything that is not an
 * integer spelling. Pass it to `JSON.parse` to read a document holding
 * several values, such as a top-level array of them.
 */
export function numberReviver(
  _key: string,
  v: unknown,
  context?: { source?: string }
): unknown {
  if (typeof v !== 'number') return v
  const source = context?.source
  need(source !== undefined, 'reading JSON numbers needs JSON source access')
  need(CANONICAL_INT.test(source), 'not an integer: ' + source)
  return Number.isSafeInteger(v) ? v : BigInt(source)
}

/** Parse JSON text and read it as one value. */
export function fromJson(
  factory: Factory,
  text: string,
  opts?: JsonOptions
): Value {
  let parsed: unknown
  try {
    parsed = JSON.parse(
      text,
      numberReviver as (k: string, v: unknown) => unknown
    )
  } catch (e) {
    if (e instanceof JsonError) throw e
    throw new JsonError('not JSON: ' + (e instanceof Error ? e.message : e))
  }
  return jsonToValue(factory, parsed, opts)
}

/**
 * Read already parsed JSON as a value, or what `valueToJson` writes. A
 * number past 2^53 has already lost its digits unless it was parsed with
 * `numberReviver`, which hands it over as a bigint, so a number that is not a
 * safe integer is refused.
 */
export function jsonToValue(
  factory: Factory,
  node: unknown,
  opts: JsonOptions = {}
): Value {
  const maxDepth = opts.maxDepth ?? MAX_DEPTH
  const read = (node: unknown, depth: number): Value => {
    need(
      typeof node === 'object' && node !== null && !Array.isArray(node),
      'a value is a JSON object'
    )
    const obj = node as Record<string, unknown>
    for (const key of Object.keys(obj)) {
      need(
        key === 'kind' || key === 'mark' || key === 'value',
        'unknown key ' + JSON.stringify(key)
      )
    }
    const kind = obj['kind']
    need(
      typeof kind === 'string' && Object.hasOwn(TAGS, kind),
      'not a kind: ' + show(kind)
    )
    const mark = obj['mark'] ?? false
    need(typeof mark === 'boolean', '"mark" is true or false')
    if (kind === 'nil') {
      need(!('value' in obj), 'nil carries no "value"')
      return factory.nil(mark)
    }
    need('value' in obj, kind + ' needs a "value"')
    const v = obj['value']

    const members = (): Value[] => {
      need(Array.isArray(v), kind + ' members are a JSON array')
      need(depth < maxDepth, `frames nest past ${maxDepth}`)
      return (v as unknown[]).map(m => read(m, depth + 1))
    }
    const once = (built: Value, written: number) => {
      need(
        built.length === written,
        kind === 'dict' ? 'duplicate dict key' : 'duplicate set member'
      )
      return built
    }

    switch (kind as ValueKind) {
      case 'number': {
        if (isRawJSON(v)) {
          // a number as `valueToJson` writes one past 2^53
          need(CANONICAL_INT.test(v.rawJSON), 'not an integer: ' + v.rawJSON)
          return factory.number(BigInt(v.rawJSON), mark)
        }
        need(
          typeof v === 'bigint' ||
            (typeof v === 'number' && Number.isSafeInteger(v)),
          'not a safe integer: ' + show(v)
        )
        return factory.number(v as number | bigint, mark)
      }
      case 'text':
      case 'symbol':
        need(typeof v === 'string', kind + ' is a JSON string')
        need((v as string).isWellFormed(), 'a lone surrogate in ' + kind)
        return kind === 'text'
          ? factory.text(v as string, mark)
          : factory.sym(v as string, mark)
      case 'bytes':
        return factory.bytes(hexBytes(v), mark)
      case 'list':
        return factory.list(members(), mark)
      case 'record': {
        const items = members()
        need(items.length > 0, 'a record needs a head')
        return factory.record(items, mark)
      }
      case 'set': {
        const items = members()
        return once(factory.set(items, mark), items.length)
      }
      default: {
        need(Array.isArray(v), 'dict entries are a JSON array')
        need(depth < maxDepth, `frames nest past ${maxDepth}`)
        const entries = (v as unknown[]).map(e => {
          need(
            Array.isArray(e) && e.length === 2,
            'a dict entry is [key, value]'
          )
          const [k, x] = e as [unknown, unknown]
          return [read(k, depth + 1), read(x, depth + 1)] as [Value, Value]
        })
        return once(factory.dict(entries, mark), entries.length)
      }
    }
  }
  return read(node, 0)
}

function hexBytes(v: unknown): Uint8Array {
  need(typeof v === 'string', 'bytes are a "0x…" hex string')
  const m = /^0x([0-9a-fA-F]*)$/.exec(v as string)
  need(m !== null, 'not a "0x…" hex string: ' + show(v))
  const digits = m[1]!
  need(digits.length % 2 === 0, 'bytes need an even count of hex digits')
  return Uint8Array.from({ length: digits.length / 2 }, (_, i) =>
    parseInt(digits.slice(2 * i, 2 * i + 2), 16)
  )
}

// ================ writing ================

/** A value as JSON text; `space` indents it, as for `JSON.stringify`. */
export function toJson(v: Value, space?: string | number): string {
  return JSON.stringify(valueToJson(v), null, space)
}

/**
 * A value as the carrier's plain JSON data, ready for `JSON.stringify`. An
 * integer past 2^53 is a raw JSON number, so it stays a number, digit for
 * digit.
 */
export function valueToJson(root: Value): JsonNode {
  const open: { frame: Frame; members: JsonNode[] }[] = []
  let out: JsonNode | undefined
  const land = (n: JsonNode) => {
    const top = open.at(-1)
    if (top === undefined) out = n
    else top.members.push(n)
  }
  for (const s of steps(root)) {
    switch (s.step) {
      case 'open':
        open.push({ frame: s.value, members: [] })
        break
      case 'atom':
        land(atomNode(s.value))
        break
      case 'close': {
        const { frame, members } = open.pop()!
        land(node(frame, frameValue(frame, members)))
      }
    }
  }
  return out!
}

function node(v: Value, value?: unknown): JsonNode {
  const n: JsonNode = { kind: v.kind }
  if (v.mark) n.mark = true
  if (value !== undefined) n.value = value
  return n
}

function atomNode(v: Atom): JsonNode {
  switch (v.kind) {
    case 'nil':
      return node(v)
    case 'number':
      return node(
        v,
        typeof v.payload === 'number' && Number.isSafeInteger(v.payload)
          ? v.payload
          : rawJSON(spelling(v.payload))
      )
    case 'text':
    case 'symbol':
      return node(v, v.payload)
    case 'bytes': {
      let hex = '0x'
      for (const b of v.payload) hex += b.toString(16).padStart(2, '0')
      return node(v, hex)
    }
  }
}

/** A frame's members as the carrier spells them: a dict's paired up. */
function frameValue(v: Frame, members: JsonNode[]): unknown {
  if (v.kind !== 'dict') return members
  const pairs: [JsonNode, JsonNode][] = []
  for (let i = 0; i < members.length; i += 2) {
    pairs.push([members[i]!, members[i + 1]!])
  }
  return pairs
}
