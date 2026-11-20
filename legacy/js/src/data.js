// @ts-check

// The public surface of `@bassline/core/data`: the value model programs work
// with. The CE byte layer under `src/codec/` has no external entry point —
// it's reached only through the doors here (`encode`, `decode`, `Decoder`).

// ---- construction ----
export {
  nil,
  int,
  text,
  symbol,
  bytes,
  list,
  record,
  dict,
  set,
  fromForeign,
  registerLowering,
  TO_VALUE,
} from './value/build.js'

// ---- the value classes, predicates, and comparison ----
export {
  BValue,
  BAtom,
  BFrame,
  BNil,
  BInt,
  BText,
  BSym,
  BBytes,
  BList,
  BRecord,
  BDict,
  BSet,
  isValue,
  isAtom,
  isFrame,
  assertValue,
  cmp,
  eq,
} from './value/value.js'

/** @typedef {import('./value/value.js').Value} Value */
/** @typedef {import('./codec/header.js').Kind} Kind */

// ---- the visitor ----
export { Visitor, walk, fold } from './value/visitor.js'

// ---- encoding / decoding ----
export { encode } from './value/ce.js'
export { decode, decodeAll, valueFromView } from './value/view.js'
export { Decoder, ValueView, CodecError } from './codec/decode.js'

// ---- the sorted collection ----
export { BTree, BTreeSet } from './btree.js'

// ---- operations over values ----
export {
  items,
  atoms,
  marked,
  hasMark,
  isData,
  withMark,
  map,
  at,
  contains,
  assoc,
  dissoc,
  similar,
  prefixes,
  isHole,
  isAnon,
  hasHoles,
  extract,
  inject,
} from './ops.js'
