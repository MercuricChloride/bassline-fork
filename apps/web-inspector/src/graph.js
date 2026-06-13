import { is } from '@bassline/core'
const SCRATCH = 'bassline'
const DOMAIN = 'bassline'
const RUNTIME = 'runtime'

const layoutOptions = {
  name: 'fcose',
  quality: 'default',
  randomize: true,
  animate: true,
  animationDuration: 700,
  animationEasing: 'ease-out',
  fit: true,
  padding: 48,
  packComponents: false,
  nodeSeparation: 100,
  nodeRepulsion: () => 6500,
  idealEdgeLength: () => 90,
}

export function installGraph(bl, cy) {
  const inspect = {
    bl,
    cy,
    refresh: () => sync(bl, cy),
    layout: () => layout(cy),
    select: selector => cy.$(selector),
    item: id => bl.items.get(id) ?? cy.getElementById(id).scratch(SCRATCH),
    value: id => inspect.item(id)?.value ?? inspect.item(id)?.record?.value,
    seed: null,
  }

  cy.scratch(SCRATCH, { bl, inspect })
  ensureRuntime(cy, bl)

  bl.on('track', e => {
    cy.batch(() => addTracked(cy, bl, e.detail))
  })
  bl.on('keep', e => {
    cy.batch(() => addLocation(cy, bl, e.detail.name, e.detail.value))
  })
  bl.on('fn-installed', e => {
    cy.batch(() => addInstalledFn(cy, bl, e.detail.name, e.detail.fn))
  })
  bl.on('fn-removed', e => {
    cy.getElementById(installsId(e.detail.name)).remove()
  })

  sync(bl, cy)
  return inspect
}

function sync(bl, cy) {
  cy.batch(() => {
    ensureRuntime(cy, bl)
    for (const record of bl.items.values()) addTracked(cy, bl, record)
    for (const [name, value] of bl.locations.entries()) {
      addLocation(cy, bl, name, value)
    }
    for (const [name, fn] of Object.entries(bl.fns))
      addInstalledFn(cy, bl, name, fn)
  })
  layout(cy)
  return cy
}

function ensureRuntime(cy, bl) {
  return node(cy, RUNTIME, 'runtime', 'bl', { value: bl })
}

function addTracked(cy, bl, record) {
  const id = valueNode(cy, bl, record.value, record.id, new Set(), record)
  edge(cy, tracksId(id), RUNTIME, id, 'tracks', 'tracks')
}

function addLocation(cy, bl, name, value) {
  const id = `location:${encode(name)}`
  const target = valueNode(cy, bl, value, id, new Set())
  node(cy, id, 'location', name, { name, value })
  edge(cy, tracksId(id), RUNTIME, id, 'tracks', 'tracks')
  edge(cy, keepsId(name), id, target, 'keeps', 'keeps')
}

function addInstalledFn(cy, bl, name, fn) {
  const target = valueNode(cy, bl, fn, `fn:${encode(name)}`, new Set())
  edge(cy, installsId(name), RUNTIME, target, 'installs', name)
}

function valueNode(cy, bl, value, fallback, seen, record = null) {
  const id =
    bl.identify(value) ??
    `${kind(value)}:${encode(fallback)}:${encode(String(value))}`
  const label = record?.note ?? shortLabel(value)

  node(cy, id, kind(value), label, { record, value })
  if (seen.has(id)) return id
  seen.add(id)

  if (is.msg(value)) {
    for (const [spelling, aWord] of value.entries) {
      const target = valueNode(cy, bl, aWord, `${id}:${encode(spelling)}`, seen)
      edge(cy, spellsId(id, spelling), id, target, 'spells', spelling, {
        spelling,
        word: aWord,
      })
    }
  } else if (is.word(value)) {
    if (is.nbound(value)) {
      const target = valueNode(cy, bl, value.noun, `${id}:noun`, seen)
      edge(cy, nounId(id), id, target, 'noun', 'noun', { value: value.noun })
    }
    if (is.vbound(value)) {
      const target = valueNode(cy, bl, value.verb, `${id}:verb`, seen)
      edge(cy, verbId(id), id, target, 'verb', 'verb', { value: value.verb })
    }
  }

  return id
}

function node(cy, id, kind, label, scratch = {}) {
  const ele = cy.getElementById(id)
  if (ele.empty()) {
    cy.add({ group: 'nodes', data: { id, kind, label, domain: DOMAIN } })
  } else {
    ele.data({ ...ele.data(), kind, label, domain: DOMAIN })
  }
  cy.getElementById(id).scratch(SCRATCH, scratch)
  return id
}

function edge(cy, id, source, target, kind, label, scratch = {}) {
  const ele = cy.getElementById(id)
  if (
    !ele.empty() &&
    (ele.data('source') !== source || ele.data('target') !== target)
  ) {
    ele.remove()
  }

  if (cy.getElementById(id).empty()) {
    cy.add({
      group: 'edges',
      data: { id, source, target, kind, label, domain: DOMAIN },
    })
  } else {
    cy.getElementById(id).data({
      ...cy.getElementById(id).data(),
      kind,
      label,
      domain: DOMAIN,
    })
  }

  cy.getElementById(id).scratch(SCRATCH, scratch)
  return id
}

function layout(cy) {
  const elements = cy.elements(`[domain = "${DOMAIN}"]`)
  if (elements.empty()) return cy
  elements.layout(layoutOptions).run()
  return cy
}

function kind(value) {
  if (is.msg(value)) return 'msg'
  if (is.word(value)) return 'word'
  if (is.fn(value)) return 'fn'
  if (is.scalar(value)) return 'scalar'
  return 'object'
}

function shortLabel(value) {
  if (is.msg(value)) return `msg:${value.entries.length}`
  if (is.word(value)) {
    return [is.nbound(value) && 'noun', is.vbound(value) && 'verb']
      .filter(Boolean)
      .join('+')
  }
  if (is.fn(value)) return value.name || '<fn>'
  if (is.string(value)) return JSON.stringify(value)
  if (is.scalar(value)) return String(value)
  if (is.array(value)) return `array:${value.length}`
  return value?.constructor?.name ?? 'object'
}

function tracksId(id) {
  return `tracks:${id}`
}

function keepsId(name) {
  return `keeps:${encode(name)}`
}

function installsId(name) {
  return `installs:${encode(name)}`
}

function spellsId(source, spelling) {
  return `spells:${source}:${encode(spelling)}`
}

function nounId(source) {
  return `noun:${source}`
}

function verbId(source) {
  return `verb:${source}`
}

function encode(value) {
  return encodeURIComponent(String(value))
}
