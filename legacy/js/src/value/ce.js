// @ts-check

// A value's canonical encoding. The BValue API never encodes for identity —
// this is a leaf you call at the wire, at a digest, at the store. No cache:
// hold the result if you need it again.

import { Encoder } from '../codec/encode.js'
import { fold } from './visitor.js'

/** @import { Value, Atom } from './value.js' */

/**
 * A value's CE bytes. Walks the value iteratively, so an arbitrarily deep
 * value still encodes.
 * @param {Value} v
 * @returns {Uint8Array}
 */
export function encode(v) {
  const e = new Encoder()
  fold(v, {
    atom: n => {
      if (n.kind === 'nil') e.putNil(n.mark)
      else e.putScalar(n.kind, n.mark, /** @type {Atom} */ (n).payloadBytes())
    },
    open: n => e.open(n.kind, n.mark),
    close: () => e.close(),
  })
  return e.bytes
}
