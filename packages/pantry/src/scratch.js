/** @import {Value, Values, Frame, Atom} from '@bassline/core/data' */
import {
  ENC,
  DEC,
  string,
  encode,
  symbol,
  bytes,
  nil,
  int,
  list,
  record,
  set,
  dict,
  eq,
} from '@bassline/core/data'
import { DatabaseSync } from 'node:sqlite'
import { readFileSync } from 'node:fs'

const SCHEMA = `
PRAGMA encoding = "UTF-8";
PRAGMA integrity_check;

CREATE TABLE
  IF NOT EXISTS all_values (
    id BLOB PRIMARY KEY,
    kind TEXT NOT NULL,
    marked INTEGER DEFAULT 0 CHECK (marked IN (0, 1)),
    payload_id BLOB REFERENCES payloads (id),
    CHECK (
      (
        kind IN ('nil', 'list', 'record', 'set', 'dict')
        AND payload_id is NULL
      )
      OR (
        kind IN ('int', 'string', 'symbol', 'bytes')
        AND payload_id is NOT NULL
      )
    )
  ) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS payloads (
  id BLOB PRIMARY KEY,
  content BLOB
) WITHOUT ROWID;

CREATE TABLE
  IF NOT EXISTS list_edges (
    parent_id BLOB NOT NULL REFERENCES all_values (id),
    value_id BLOB NOT NULL REFERENCES all_values (id),
    pos INTEGER NOT NULL,
    PRIMARY KEY (parent_id, pos, value_id)
  ) WITHOUT ROWID;

CREATE TABLE
  IF NOT EXISTS record_edges (
    parent_id BLOB NOT NULL REFERENCES all_values (id),
    value_id BLOB NOT NULL REFERENCES all_values (id),
    pos INTEGER NOT NULL,
    PRIMARY KEY (parent_id, pos, value_id)
  ) WITHOUT ROWID;

CREATE TABLE
  IF NOT EXISTS dict_edges (
    parent_id BLOB NOT NULL REFERENCES all_values (id),
    key_id BLOB NOT NULL REFERENCES all_values (id),
    value_id BLOB NOT NULL REFERENCES all_values (id),
    PRIMARY KEY (parent_id, key_id, value_id)
  ) WITHOUT ROWID;

CREATE TABLE
  IF NOT EXISTS set_edges (
    parent_id BLOB NOT NULL REFERENCES all_values (id),
    value_id BLOB NOT NULL REFERENCES all_values (id),
    PRIMARY KEY (parent_id, value_id)
  ) WITHOUT ROWID;
`
const EMPTY = new Uint8Array(0)

/**
 *
 * @param {Uint8Array} buf
 * @returns {Promise<Uint8Array>}
 */
async function bufId(buf) {
  if (buf.length <= 32) {
    return buf
  } else {
    const hash = crypto.subtle.digest('SHA-256', buf)
    return new Uint8Array(await hash)
  }
}

/** @param {Value} v */
const idOf = v => bufId(encode(v))

/** @param {Value} v */
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

/** @param {DatabaseSync} db  */
function createDriver(db) {
  const insert = {
    value: db.prepare(
      'INSERT INTO all_values (id, kind, marked, payload_id) VALUES (?, ?, ?, ?)'
    ),
    payload: db.prepare(
      `INSERT OR IGNORE INTO payloads (id, content) VALUES (?, ?);`
    ),
    listEdge: db.prepare(
      'INSERT INTO list_edges (parent_id, pos, value_id) VALUES (?, ?, ?);'
    ),
    recordEdge: db.prepare(
      'INSERT INTO record_edges (parent_id, pos, value_id) VALUES (?, ?, ?);'
    ),
    dictEdge: db.prepare(
      'INSERT INTO dict_edges (parent_id, key_id, value_id) VALUES (?, ?, ?);'
    ),
    setEdge: db.prepare(
      'INSERT INTO set_edges (parent_id, value_id) VALUES (?, ?);'
    ),
  }
  const select = {
    payloadId: db.prepare('SELECT id FROM payloads WHERE id = ?;'),
    payload: db.prepare('SELECT content FROM payloads WHERE id = ?;'),
    value: db.prepare('SELECT * FROM all_values WHERE id = ?;'),
    dictChildren: db.prepare('SELECT * FROM dict_edges WHERE parent_id = ?;'),
    dictChild: db.prepare(
      'SELECT * FROM dict_edges WHERE parent_id = ? AND key_id = ?;'
    ),
    listChildren: db.prepare('SELECT * FROM list_edges WHERE parent_id = ?;'),
    listChild: db.prepare(
      'SELECT * FROM list_edges WHERE parent_id = ? AND pos = ?;'
    ),
    recordChildren: db.prepare(
      'SELECT * FROM record_edges WHERE parent_id = ?;'
    ),
    recordChild: db.prepare(
      'SELECT * FROM record_edges WHERE parent_id = ? AND pos = ?;'
    ),
    setChildren: db.prepare('SELECT * FROM set_edges WHERE parent_id = ?;'),
    setChild: db.prepare(
      'SELECT * FROM set_edges WHERE parent_id = ? AND value_id = ?;'
    ),
  }
  return {
    insert,
    select,
  }
}

class Pantry {
  constructor(path, opts = {}) {
    this.db = new DatabaseSync(path, opts)
    this.db.exec(SCHEMA)
    const driver = createDriver(this.db)
    this.insert = driver.insert
    this.select = driver.select
  }

  /**
   * @template T
   * @param {() => T} fn
   */
  tx(fn) {
    if (this.db.isTransaction) {
      return fn()
    }
    this.db.exec('BEGIN IMMEDIATE')
    try {
      const out = fn()
      this.db.exec('COMMIT')
      return out
    } catch (e) {
      this.db.exec('ROLLBACK')
      throw e
    }
  }

  /** @param {Value} v */
  async hold(v) {
    switch (v.kind) {
      case 'nil':
      case 'int':
      case 'string':
      case 'symbol':
      case 'bytes':
        return this.holdAtom(v)
      case 'dict':
      case 'set':
      case 'list':
      case 'record':
        return this.holdFrame(v)
      default:
        throw new Error('holdValue: unknown value kind')
    }
  }

  /** @param {Atom} v  */
  async holdAtom(v) {
    const id = await idOf(v)
    const payload = payloadOf(v)
    const payloadId = await bufId(payload)

    if (this.select.value.get(id)) {
      return id
    }

    if (v.kind === 'nil') {
      this.insert.value.run(id, v.kind, Number(v.actionable), null)
    } else {
      if (!this.select.payloadId.get(payloadId)) {
        this.insert.payload.run(payloadId, payload)
      }
      this.insert.value.run(id, v.kind, Number(v.actionable), payloadId)
    }

    return id
  }

  /** @param {Frame} frame */
  async holdFrame(frame) {
    const id = await idOf(frame)
    if (this.select.value.get(id)) {
      return id
    }

    await this.tx(async () => {
      this.insert.value.run(id, frame.kind, Number(frame.actionable), null)

      switch (frame.kind) {
        case 'list':
          for (let i = 0; i < frame.value.length; i++) {
            const valueId = await this.hold(frame.value[i])
            const exists = this.select.listChild.get(id, i)
            if (exists) continue
            this.insert.listEdge.run(id, i, valueId)
          }
          break

        case 'record':
          for (let i = 0; i < frame.value.length; i++) {
            const valueId = await this.hold(frame.value[i])
            const exists = this.select.recordChild.get(id, i)
            if (exists) continue
            this.insert.recordEdge.run(id, i, valueId)
          }
          break

        case 'dict':
          for (const [k, v] of frame.value) {
            const keyId = await this.hold(k)
            const valueId = await this.hold(v)
            const exists = this.select.dictChild.get(id, keyId)
            if (exists) continue
            this.insert.dictEdge.run(id, keyId, valueId)
          }
          break

        case 'set':
          for (const v of frame.value) {
            const valueId = await this.hold(v)
            const exists = this.select.setChild.get(id, valueId)
            if (exists) continue
            this.insert.setEdge.run(id, valueId)
          }
          break

        default:
          throw new Error('holdFrame: unknown frame kind')
      }
    })

    return id
  }

  async materialize(id) {
    const row = this.select.value.get(id)
    if (!row) {
      throw new Error('materialize: value not found')
    }
    const marked = Boolean(row.marked)
    const { kind, payload_id: payloadId } = row
    const payload = payloadId && this.select.payload.get(payloadId).content

    if (kind === 'nil') {
      return nil(marked)
    } else if (kind === 'bytes') {
      return bytes(payload, marked)
    } else if (kind === 'string') {
      return string(DEC.decode(payload), marked)
    } else if (kind === 'symbol') {
      return symbol(DEC.decode(payload), marked)
    } else if (kind === 'int') {
      return int(Number(DEC.decode(payload)), marked)
    } else if (kind === 'list') {
      const children = []
      for (const row of this.select.listChildren.all(id)) {
        const child = await this.materialize(row.value_id)
        children[row.pos] = child
      }
      return list(children, marked)
    } else if (kind === 'record') {
      const children = []
      for (const row of this.select.recordChildren.all(id)) {
        const child = await this.materialize(row.value_id)
        children[row.pos] = child
      }
      return record(children, marked)
    } else if (kind === 'dict') {
      const children = []
      for (const row of this.select.dictChildren.all(id)) {
        const key = await this.materialize(row.key_id)
        const value = await this.materialize(row.value_id)
        children.push([key, value])
      }
      return dict(children, marked)
    } else if (kind === 'set') {
      const children = []
      for (const row of this.select.setChildren.all(id)) {
        const child = await this.materialize(row.value_id)
        children.push(child)
      }
      return set(children, marked)
    } else {
      throw new Error('materialize: unknown atom kind')
    }
  }
}

const p = new Pantry('foo.db')

const content = readFileSync('./alt-schema.sql', 'utf-8').repeat(20)

const chunks = content
  .match(/.{1,1000}/g)
  .flatMap(chunk => [
    string(chunk),
    bytes(ENC.encode(chunk)),
    symbol(chunk),
    string(chunk, true),
    bytes(ENC.encode(chunk), true),
    symbol(chunk, true),
  ])

const asSet = set(chunks)
const asList = list(chunks)
const asRecord = record(chunks)
const asDict = dict(chunks.map((s, i) => [string(`key${i}`), s]))

const schemaFile = string(content)

const items = [schemaFile, asSet, asList, asRecord, asDict]

const ids = await Promise.all(items.map(item => p.hold(item)))
const materialized = await Promise.all(ids.map(id => p.materialize(id)))

for (let i = 0; i < items.length; i++) {
  const doesMatch = eq(items[i], materialized[i])
  console.log('match:', doesMatch)
}

const values = p.db
  .prepare('SELECT id FROM all_values')
  .all()
  .map(row => row.id)

const all = await Promise.all(values.map(id => p.materialize(id)))

let sum = 0
for (const v of all) {
  console.log(v)
  sum += encode(v).byteLength
}

console.log('total bytes:', sum)
