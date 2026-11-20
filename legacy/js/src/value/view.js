// @ts-check

// The bytes -> Value bridge, and the one-shot decode entry points. This is
// the only place codec/decode.js meets value/: the byte layer stays clean.

import { Decoder, CodecError } from '../codec/decode.js'
import { decodeUtf8 } from '../codec/payload.js'
import { BTree, BTreeSet } from '../btree.js'
import {
  BNil,
  BInt,
  BText,
  BSym,
  BBytes,
  BList,
  BRecord,
  BDict,
  BSet,
  byValue,
} from './value.js'

/** @import { Value } from './value.js' */
/** @import { ValueView } from '../codec/decode.js' */

/**
 * Build a {@link Value} from a validated {@link ValueView}. Trusts the view's
 * validation: dict / set members are already canonical and unique, so they go
 * straight into their trees.
 * @param {ValueView} view
 * @returns {Value}
 */
export function valueFromView(view) {
  const mark = view.mark
  switch (view.kind) {
    case 'nil':
      return new BNil(mark)
    case 'number':
      return new BInt(BigInt(decodeUtf8(view.payloadBytes)), mark)
    case 'text':
      return new BText(decodeUtf8(view.payloadBytes), mark)
    case 'symbol':
      return new BSym(decodeUtf8(view.payloadBytes), mark)
    case 'bytes':
      return new BBytes(view.payloadBytes.slice(), mark)
    case 'list':
      return new BList(view.children().map(valueFromView), mark)
    case 'record':
      return new BRecord(view.children().map(valueFromView), mark)
    case 'set': {
      const s = new BTreeSet(byValue)
      for (const c of view.children()) s.add(valueFromView(c))
      return new BSet(s, mark)
    }
    case 'dict': {
      const cs = view.children()
      const t = new BTree(byValue)
      for (let i = 0; i < cs.length; i += 2) {
        t.set(valueFromView(cs[i]), valueFromView(cs[i + 1]))
      }
      return new BDict(t, mark)
    }
    default:
      throw new CodecError('unknown kind ' + view.kind)
  }
}

/**
 * Decode the sequence of values in `bytes` (a document). Trailing partial
 * bytes are an error.
 * @param {Uint8Array} bytes
 * @param {{ maxDepth?: number, maxValueBytes?: number }} [opts]
 * @returns {Value[]}
 */
export function decodeAll(bytes, opts) {
  const d = new Decoder(opts)
  const views = d.push(bytes)
  if (d.pending) throw new CodecError('unexpected end of input')
  return views.map(valueFromView)
}

/**
 * Decode exactly one value; trailing bytes are an error.
 * @param {Uint8Array} bytes
 * @param {{ maxDepth?: number, maxValueBytes?: number }} [opts]
 * @returns {Value}
 */
export function decode(bytes, opts) {
  const vs = decodeAll(bytes, opts)
  if (vs.length !== 1) {
    throw new CodecError('expected exactly one value, got ' + vs.length)
  }
  return vs[0]
}
