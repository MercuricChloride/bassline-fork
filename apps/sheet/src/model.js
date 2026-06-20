// Pure helpers over a sheet *value*. A formula sheet is
//   <sheet <cell NAME FORMULA> ..>
// and a recalc'd (valued) sheet is
//   <sheet <cell NAME FORMULA VALUE> ..>
// where NAME is a symbol, FORMULA/VALUE are values. Nothing here evaluates —
// these just read and rebuild the document the evaluator works on.

import { record, sym } from '@bassline/core/data'
import { print } from '@bassline/core/text'

const cellRecords = sheet => sheet.fields

/**
 * [{ name, formula }] for a formula sheet.
 * @param sheet
 */
export function cells(sheet) {
  return cellRecords(sheet).map(cell => ({
    name: cell.fields[0].value,
    formula: cell.fields[1],
  }))
}

/**
 * The FORMULA value of a named cell, or null.
 * @param sheet
 * @param name
 */
export function getFormula(sheet, name) {
  const cell = cellRecords(sheet).find(c => c.fields[0].value === name)
  return cell ? cell.fields[1] : null
}

/**
 * The computed VALUE of a named cell in a valued sheet, or null.
 * @param valuedSheet
 * @param name
 */
export function cellValue(valuedSheet, name) {
  const cell = cellRecords(valuedSheet).find(c => c.fields[0].value === name)
  return cell ? cell.fields[2] : null
}

/**
 * A new sheet with `name`'s formula replaced (or the cell added).
 * @param sheet
 * @param name
 * @param formula
 */
export function setFormula(sheet, name, formula) {
  let found = false
  const fields = cellRecords(sheet).map(cell => {
    if (cell.fields[0].value !== name) return cell
    found = true
    return record(sym('cell'), cell.fields[0], formula)
  })
  if (!found) fields.push(record(sym('cell'), sym(name), formula))
  return record(sym('sheet'), ...fields)
}

// --- A1 addressing ---

/**
 * "B12" -> { col, row } (0-based), or null if not an A1 name.
 * @param name
 */
export function a1(name) {
  const m = /^([A-Za-z]+)(\d+)$/.exec(name)
  if (!m) return null
  let col = 0
  for (const ch of m[1].toUpperCase()) col = col * 26 + (ch.charCodeAt(0) - 64)
  return { col: col - 1, row: Number(m[2]) - 1 }
}

/**
 * 0 -> "A", 25 -> "Z", 26 -> "AA".
 * @param i
 */
export function colName(i) {
  let s = ''
  for (let n = i + 1; n > 0; n = Math.floor((n - 1) / 26)) {
    s = String.fromCharCode(65 + ((n - 1) % 26)) + s
  }
  return s
}

/**
 * Grid size that covers the used cells, with a little room to grow.
 * @param cellList
 */
export function extent(cellList) {
  let maxCol = 0
  let maxRow = 0
  for (const { name } of cellList) {
    const p = a1(name)
    if (!p) continue
    maxCol = Math.max(maxCol, p.col)
    maxRow = Math.max(maxRow, p.row)
  }
  return { cols: Math.max(maxCol + 2, 5), rows: Math.max(maxRow + 2, 8) }
}

// --- rendering a value to a cell string ---

const ERROR_TEXT = { cycle: '#CYCLE!', unbound: '#NAME?' }

export const isError = v =>
  v?.kind === 'record' && v.head.kind === 'symbol' && v.head.value === 'error'

export const isText = v => v?.kind === 'string'

export function display(value) {
  if (!value) return ''
  switch (value.kind) {
    case 'nil':
      return ''
    case 'int':
    case 'float':
      return String(value.value)
    case 'bool':
      return value.value ? 'true' : 'false'
    case 'string':
    case 'symbol':
      return value.value
    case 'record':
      if (isError(value)) {
        const tag = value.fields[0]?.value
        return ERROR_TEXT[tag] ?? `#${String(tag).toUpperCase()}!`
      }
      return print(value)
    default:
      return print(value)
  }
}
