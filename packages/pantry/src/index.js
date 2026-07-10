// @ts-check

// A home for values. Values are timeless and placeless; the home is
// where a participant gives them standing: custody (it can produce
// them), meaning (they bear on each other through readings), and voice
// (it can speak them). The home is not a value — it is a speaker of
// values. Any one thing it says is a canonical value with full CE
// identity; no utterance exhausts the speaker.
//
// Three methods, values in, values out, each total:
//   hold(v)  → the smallest denotation of what is now in custody
//   solve(v) → what v locally denotes, followed to ground; v itself
//              when it cannot advance (the frontier)
//   run(v)   → the answer to reading v; v itself when the home has no
//              reading for it
// Refusal is the identity: one equality tells a caller whether the home
// took the value anywhere.
/** @import {Value} from '@bassline/core/data' */
import { DatabaseSync } from 'node:sqlite'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { homedir } from 'node:os'
import { assertValue } from '@bassline/core/data'
import { createTruth, withTx } from './store.js'
import { createFolds } from './folds.js'
import { createSweep } from './sweep.js'
import { createReadings } from './readings.js'
import { denote } from './refs.js'

export {
  refOf,
  refTo,
  refHash,
  isRef,
  hashOf,
  denote,
  REF_COST,
  hex,
  shortHex,
} from './refs.js'
export { match, isHole, hasHole } from './match.js'
export {
  saveValues,
  loadValues,
  parseValues,
  BINARY_EXT,
  TEXT_EXT,
} from '@bassline/core/files'

export const DEFAULT_STORE = '~/.pantry/main.db'

/** @param {string} path */
function resolvePath(path) {
  if (path === ':memory:') return path
  const expanded = path.startsWith('~/')
    ? resolve(homedir(), path.slice(2))
    : resolve(path)
  mkdirSync(dirname(expanded), { recursive: true })
  return expanded
}

/**
 * Open (or create) a home.
 * @param {string} [path]
 * @param {{
 *   now?: () => number,
 *   readings?: Record<string, (fields: readonly Value[], home: unknown) => Value | undefined>,
 * }} [opts] clock injection for tests; host readings installed at open
 */
export function open(path = DEFAULT_STORE, opts = {}) {
  const file = resolvePath(path)
  const db = new DatabaseSync(file)
  db.exec('PRAGMA journal_mode = WAL')
  db.exec('PRAGMA foreign_keys = ON')
  db.exec('PRAGMA synchronous = NORMAL')

  const truth = createTruth(db, opts)
  const folds = createFolds(db)
  const sweeper = createSweep(db, truth)
  const readings = createReadings(db, truth, folds, sweeper)

  // the index catches up to whatever arrived while we weren't looking
  withTx(db, () => folds.advance(truth.contentWater()))

  /** @type {Set<(e: {value: Value, denotation: Value, created: number}) => void>} */
  const listeners = new Set()

  /**
   * Hold a value: custody of it and every subvalue, plus the fact that
   * the home was told it directly. Idempotent custody, fresh speech.
   * Answers with the smallest denotation of what was held.
   * @param {Value} v
   * @returns {Value}
   */
  function hold(v) {
    assertValue(v)
    const created = withTx(db, () => {
      truth.takeCreated()
      truth.utter(v)
      const n = truth.takeCreated()
      folds.advance(truth.contentWater())
      return n
    })
    const d = denote(v)
    for (const fn of listeners) fn({ value: v, denotation: d, created })
    return d
  }

  const home = {
    hold,
    solve: readings.solve,
    run: readings.run,
    // host plumbing, not part of what the home says
    onHold: (
      /** @type {(e: {value: Value, denotation: Value, created: number}) => void} */ fn
    ) => {
      listeners.add(fn)
      return () => listeners.delete(fn)
    },
    refoldCaches: () => withTx(db, () => folds.refold(truth.contentWater())),
    path: file,
    close: () => db.close(),
  }
  readings.extend(opts.readings, home)
  return home
}
