import cytoscape from 'cytoscape'
import fcose from 'cytoscape-fcose'

cytoscape.use(fcose)

export const cyContainer = document.getElementById('cy')

export const cy = cytoscape({
  container: cyContainer,
  elements: [],
  wheelSensitivity: 0.2,
  layout: { name: 'preset' },
  style: [
    {
      selector: 'node',
      style: {
        'background-color': '#607d8b',
        color: '#1b1f24',
        label: 'data(label)',
        'font-size': 11,
        'text-valign': 'bottom',
        'text-margin-y': 6,
        'text-wrap': 'wrap',
        'text-max-width': 110,
        width: 32,
        height: 32,
      },
    },
    {
      selector: 'node[kind = "runtime"]',
      style: {
        'background-color': '#263238',
        color: '#111827',
        width: 46,
        height: 46,
      },
    },
    {
      selector: 'node[kind = "msg"]',
      style: { 'background-color': '#2f80ed' },
    },
    {
      selector: 'node[kind = "word"]',
      style: { 'background-color': '#27ae60' },
    },
    {
      selector: 'node[kind = "fn"]',
      style: { 'background-color': '#bb6bd9' },
    },
    {
      selector: 'node[kind = "location"]',
      style: { 'background-color': '#f2c94c' },
    },
    {
      selector: 'node[kind = "scalar"]',
      style: { 'background-color': '#f2994a' },
    },
    {
      selector: 'edge',
      style: {
        width: 2,
        'line-color': '#9aa4b2',
        'target-arrow-color': '#9aa4b2',
        'target-arrow-shape': 'triangle',
        'curve-style': 'bezier',
        label: 'data(label)',
        'font-size': 9,
        color: '#475569',
        'text-background-color': '#ffffff',
        'text-background-opacity': 0.75,
        'text-background-padding': 2,
      },
    },
    {
      selector: 'edge[kind = "spells"]',
      style: { 'line-color': '#2f80ed', 'target-arrow-color': '#2f80ed' },
    },
    {
      selector: 'edge[kind = "noun"]',
      style: { 'line-color': '#27ae60', 'target-arrow-color': '#27ae60' },
    },
    {
      selector: 'edge[kind = "verb"]',
      style: { 'line-color': '#bb6bd9', 'target-arrow-color': '#bb6bd9' },
    },
  ],
})

globalThis.cy = cy

let _ns = 'system'
export function ns(...args) {
  if (args.length === 0) return _ns
  else {
    const old = _ns
    _ns = args[0]
    return old
  }
}

export function withNs(name, fn) {
  const old = ns(name)
  try {
    return fn()
  } finally {
    ns(old)
  }
}

export function add(...els) {
  return cy.add(els).data('ns', ns())
}
