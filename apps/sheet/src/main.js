// The spreadsheet controller: holds a formula sheet (the source of truth),
// recalcs it into a valued sheet for display, and writes edits back. The whole
// loop is .blt text -> values -> grid -> edit -> recalc -> re-serialize.

import { makeEvaluator } from '@bassline/core/lang'
import { read, print } from '@bassline/core/text'
import * as M from './model.js'

const SAMPLE = `<sheet
  <cell A1 "Rent">  <cell B1 1200>
  <cell A2 "Food">  <cell B2 450>
  <cell A3 "Fun">   <cell B3 200>
  <cell A4 "Total"> <cell B4 \`<+ \`B1 \`B2 \`B3>>>`

const ev = makeEvaluator()
// recalc marks the sheet record actionable and runs the `sheet` command, which
// builds a fresh lazy env each call — so this is repeatable and side-effect free.
const recalc = sheet => ev.visit(sheet.toActionable())

let formulaSheet = read(SAMPLE)[0]
let selected = 'A1'

const byId = id => document.getElementById(id)
const gridEl = byId('grid')
const sourceEl = byId('source')
const barEl = byId('formula-bar')
const addrEl = byId('addr')

function render() {
  const valued = recalc(formulaSheet)
  renderGrid(valued)
  renderBar()
  sourceEl.value = print(formulaSheet)
}

function renderGrid(valued) {
  const list = M.cells(formulaSheet)
  const present = new Set(list.map(c => c.name))
  const { cols, rows } = M.extent(list)

  const table = document.createElement('table')

  const headRow = table.insertRow()
  headRow.appendChild(document.createElement('th')) // corner
  for (let c = 0; c < cols; c++) {
    const th = document.createElement('th')
    th.textContent = M.colName(c)
    headRow.appendChild(th)
  }

  for (let r = 0; r < rows; r++) {
    const tr = table.insertRow()
    const rowHead = document.createElement('th')
    rowHead.textContent = String(r + 1)
    tr.appendChild(rowHead)
    for (let c = 0; c < cols; c++) {
      const name = M.colName(c) + (r + 1)
      const td = tr.insertCell()
      td.dataset.name = name
      if (present.has(name)) {
        const value = M.cellValue(valued, name)
        td.textContent = M.display(value)
        if (M.isError(value)) td.classList.add('err')
        if (M.isText(value)) td.classList.add('text')
      }
      if (name === selected) td.classList.add('sel')
    }
  }

  gridEl.replaceChildren(table)
}

function renderBar() {
  addrEl.textContent = selected
  const formula = M.getFormula(formulaSheet, selected)
  barEl.value = formula ? print(formula) : ''
}

// select a cell
gridEl.addEventListener('click', event => {
  const td = event.target.closest('td[data-name]')
  if (!td) return
  selected = td.dataset.name
  render()
  barEl.focus()
})

// commit a formula edit
barEl.addEventListener('keydown', event => {
  if (event.key === 'Enter') commitFormula(barEl.value)
})

function commitFormula(text) {
  const trimmed = text.trim()
  try {
    const formula = read(trimmed === '' ? 'nil' : trimmed)[0]
    formulaSheet = M.setFormula(formulaSheet, selected, formula)
    render()
  } catch (err) {
    barEl.classList.add('invalid')
    console.warn('formula read error:', err.message)
    setTimeout(() => barEl.classList.remove('invalid'), 600)
  }
}

// edit the whole document the other way: re-read the .blt source
sourceEl.addEventListener('change', () => {
  try {
    formulaSheet = read(sourceEl.value)[0]
    render()
  } catch (err) {
    console.warn('source read error:', err.message)
  }
})

render()
