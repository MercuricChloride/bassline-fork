// @ts-check

// Truth is three tables — value, atom, edge — plus the utterance log.
// Everything else in the file is a disposable cache. Row ids, utterance
// seqs, and arrival times are the home's own runtime record — testimony,
// never substrate — and appear in no value the home speaks unprompted.
//
// Use vs mention: holding a value utters it; the same value appearing
// inside another held value is quotation. Only utterances are read as
// facts, so quoting never names.
/** @import {Value} from '@bassline/core/data' */
import {
  encode,
  isAtom,
  TAGS,
  nil,
  int,
  string,
  symbol,
  bytes,
  list,
  record,
  dict,
  set,
} from '@bassline/core/data'
import { hashCE } from './refs.js'

const DDL = `
CREATE TABLE IF NOT EXISTS kinds (
  tag INTEGER PRIMARY KEY,
  name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS value (
  -- AUTOINCREMENT: ids are watermarks; a swept id must never be reissued
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  hash BLOB NOT NULL UNIQUE,
  kind INTEGER NOT NULL REFERENCES kinds(tag) CHECK (kind BETWEEN 1 AND 9),
  marked INTEGER NOT NULL DEFAULT 0 CHECK (marked IN (0,1)),
  size INTEGER NOT NULL,
  at INTEGER NOT NULL
);

-- pure content, shared across kind and mark: a marked and an unmarked
-- bytes value, or a string and a symbol with one spelling, reference the
-- same payload row
CREATE TABLE IF NOT EXISTS payload (
  id INTEGER PRIMARY KEY,
  content BLOB NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS atom (
  value_id INTEGER PRIMARY KEY REFERENCES value(id),
  payload_id INTEGER NOT NULL REFERENCES payload(id)
);

CREATE TABLE IF NOT EXISTS edge (
  parent INTEGER NOT NULL REFERENCES value(id),
  pos INTEGER NOT NULL,
  child INTEGER NOT NULL REFERENCES value(id),
  PRIMARY KEY (parent, pos),
  CHECK (parent > child)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS edge_child ON edge(child);

CREATE TABLE IF NOT EXISTS utterance (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  value_id INTEGER NOT NULL UNIQUE REFERENCES value(id),
  at INTEGER NOT NULL
);
`

const ENC = new TextEncoder()
const DEC = new TextDecoder()
const EMPTY = new Uint8Array(0)

/**
 * The atom's stored payload, derived from the value itself. This is
 * byte-identical to the payload inside the canonical encoding.
 * @param {Value} v
 */
function payloadOf(v) {
  switch (v.kind) {
    case 'nil':
      return EMPTY
    case 'int':
      return ENC.encode(v.value.toString())
    case 'string':
    case 'symbol':
      return ENC.encode(v.value)
    case 'bytes':
      return v.value
    default:
      throw new Error('payloadOf: not an atom')
  }
}

/**
 * Run fn inside a transaction, rolling back on any throw.
 * @template T
 * @param {import('node:sqlite').DatabaseSync} db
 * @param {() => T} fn
 * @returns {T}
 */
export function withTx(db, fn) {
  db.exec('BEGIN IMMEDIATE')
  try {
    const out = fn()
    db.exec('COMMIT')
    return out
  } catch (e) {
    db.exec('ROLLBACK')
    throw e
  }
}

// Bumped whenever the private schema changes shape — including the shape
// of what the one materialized index covers. An old store file refuses
// to open: the migration path is speaking with the old code and adopting
// with the new, never ALTER TABLE (see SPEC.md).
export const SCHEMA_VERSION = 4

/**
 * The truth layer over an open database. Owns custody and utterance;
 * knows nothing about readings or reports.
 * @param {import('node:sqlite').DatabaseSync} db
 * @param {{now?: () => number}} [opts]
 */
export function createTruth(db, opts = {}) {
  const now = opts.now ?? Date.now
  const tables = Number(
    db
      .prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table'")
      .get().n
  )
  const version = Number(db.prepare('PRAGMA user_version').get().user_version)
  if (tables > 0 && version !== SCHEMA_VERSION) {
    throw new Error(
      `this store file uses pantry schema ${version}, the code speaks ${SCHEMA_VERSION}; ` +
        'the migration is an adoption — export speech with the old code, adopt into a fresh store'
    )
  }
  db.exec(DDL)
  db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`)
  const insKind = db.prepare(
    'INSERT OR IGNORE INTO kinds (tag, name) VALUES (?, ?)'
  )
  for (const [name, tag] of Object.entries(TAGS)) insKind.run(tag, name)

  const insValue = db.prepare(
    'INSERT OR IGNORE INTO value (hash, kind, marked, size, at) VALUES (?, ?, ?, ?, ?)'
  )
  const byHash = db.prepare('SELECT id FROM value WHERE hash = ?')
  // coalesce: some empty Uint8Arrays bind as NULL (zero-length views over
  // zero-length buffers); an empty payload must still be an empty BLOB
  const insPayload = db.prepare(
    "INSERT OR IGNORE INTO payload (content) VALUES (coalesce(?, x''))"
  )
  const payloadIdOf = db.prepare(
    "SELECT id FROM payload WHERE content = coalesce(?, x'')"
  )
  const insAtom = db.prepare(
    'INSERT INTO atom (value_id, payload_id) VALUES (?, ?)'
  )
  const insEdge = db.prepare(
    'INSERT INTO edge (parent, pos, child) VALUES (?, ?, ?)'
  )
  // OR REPLACE: re-uttering a value is new speech — it takes a fresh seq,
  // so a re-asserted fact becomes the latest fact again
  const insUtterance = db.prepare(
    'INSERT OR REPLACE INTO utterance (value_id, at) VALUES (?, ?)'
  )
  const rowOf = db.prepare('SELECT id, kind, marked FROM value WHERE id = ?')
  const hashRowOf = db.prepare('SELECT hash FROM value WHERE id = ?')
  const atomOf = db.prepare(
    `SELECT p.content AS payload FROM atom a
     JOIN payload p ON p.id = a.payload_id
     WHERE a.value_id = ?`
  )
  const kidsOf = db.prepare(
    'SELECT child FROM edge WHERE parent = ? ORDER BY pos'
  )
  const maxValueId = db.prepare('SELECT coalesce(max(id), 0) AS w FROM value')
  const utteranceRows = db.prepare(
    'SELECT value_id AS id FROM utterance ORDER BY seq'
  )
  // custody roots: everything held that no held value contains. Uttered
  // or not — root-ness is about containment, speech is the log's business.
  const rootRows = db.prepare(
    `SELECT id FROM value
     WHERE id NOT IN (SELECT child FROM edge)
     ORDER BY id`
  )
  const actRows = db.prepare(
    'SELECT value_id AS id, at FROM utterance ORDER BY seq'
  )
  const actRowsSince = db.prepare(
    'SELECT value_id AS id, at FROM utterance WHERE at >= ? ORDER BY seq'
  )

  let created = 0

  /**
   * Postorder custody: children first, so ids stay topological and the
   * acyclicity CHECK bites. Atom and edge inserts are plain INSERTs on
   * purpose — a violated constraint must fail, not vanish.
   * @param {Value} v
   * @returns {number} the value's row id
   */
  function ingest(v) {
    const ce = encode(v)
    const h = hashCE(ce)
    const hit = byHash.get(h)
    if (hit) return Number(hit.id)
    const kids = isAtom(v)
      ? null
      : (v.kind === 'dict' ? v.value.flat() : v.value).map(ingest)
    const r = insValue.run(
      h,
      TAGS[v.kind],
      v.actionable ? 1 : 0,
      ce.length,
      now()
    )
    if (r.changes === 0) return Number(byHash.get(h).id)
    const id = Number(r.lastInsertRowid)
    created++
    if (kids === null) {
      const content = payloadOf(v)
      insPayload.run(content)
      insAtom.run(id, Number(payloadIdOf.get(content).id))
    } else {
      kids.forEach((kid, pos) => insEdge.run(id, pos, kid))
    }
    return id
  }

  /**
   * Hold a value as an utterance: custody plus the fact that *we* were
   * told this, directly. Re-uttering is idempotent custody, new speech.
   * @param {Value} v
   */
  function utter(v) {
    const id = ingest(v)
    insUtterance.run(id, now())
    return id
  }

  /** Number of value rows created since the last call. */
  function takeCreated() {
    const n = created
    created = 0
    return n
  }

  /**
   * Rows back to a Value.
   * @param {number} id
   * @returns {Value}
   */
  function materialize(id) {
    const row = rowOf.get(id)
    if (!row) throw new Error(`no value with id ${id}`)
    const kind = Number(row.kind)
    const m = Number(row.marked) === 1
    if (kind <= TAGS.bytes) {
      const p = atomOf.get(id)?.payload ?? EMPTY
      switch (kind) {
        case TAGS.nil:
          return nil(m)
        case TAGS.int:
          return int(BigInt(DEC.decode(p)), m)
        case TAGS.string:
          return string(DEC.decode(p), m)
        case TAGS.symbol:
          return symbol(DEC.decode(p), m)
        case TAGS.bytes:
          return bytes(new Uint8Array(p), m)
      }
    }
    const kids = kidsOf.all(id).map(r => materialize(Number(r.child)))
    switch (kind) {
      case TAGS.list:
        return list(kids, m)
      case TAGS.record:
        return record(kids, m)
      case TAGS.dict: {
        /** @type {Array<[Value, Value]>} */
        const entries = []
        for (let i = 0; i < kids.length; i += 2)
          entries.push([kids[i], kids[i + 1]])
        return dict(entries, m)
      }
      case TAGS.set:
        return set(kids, m)
      default:
        throw new Error(`invalid kind tag ${kind}`)
    }
  }

  /**
   * The row id a value has here, or null when not held.
   * @param {Value} v
   */
  function idOf(v) {
    const hit = byHash.get(hashCE(encode(v)))
    return hit ? Number(hit.id) : null
  }

  /**
   * The row id of a hash's pre-image, or null when not held.
   * @param {Uint8Array} hash
   */
  function idOfHash(hash) {
    const hit = byHash.get(hash)
    return hit ? Number(hit.id) : null
  }

  /** @param {number} id */
  function hashOfId(id) {
    const row = hashRowOf.get(id)
    if (!row) throw new Error(`no value with id ${id}`)
    return new Uint8Array(row.hash)
  }

  /** The content high water: max value row id. Index machinery only. */
  function contentWater() {
    return Number(maxValueId.get().w)
  }

  /** Row ids of everything uttered, in spoken order. */
  function speechIds() {
    return utteranceRows.all().map(r => Number(r.id))
  }

  /** Row ids of every custody root, containment-wise. */
  function rootIds() {
    return rootRows.all().map(r => Number(r.id))
  }

  /**
   * The journal, as rows: what was said, when (local ms). Optionally
   * only speech at or after sinceMs.
   * @param {number} [sinceMs]
   */
  function acts(sinceMs) {
    const rows =
      sinceMs === undefined ? actRows.all() : actRowsSince.all(sinceMs)
    return rows.map(r => ({ id: Number(r.id), at: Number(r.at) }))
  }

  return {
    db,
    now,
    ingest,
    utter,
    takeCreated,
    materialize,
    idOf,
    idOfHash,
    hashOfId,
    contentWater,
    speechIds,
    rootIds,
    acts,
  }
}
