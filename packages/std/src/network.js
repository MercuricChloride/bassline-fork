const network = {
  nodes: [],
  rules: [],
  node(...fns) {
    const node = fns.reduce((acc, curr) => {
      return curr(acc, this)
    }, {})
    this.nodes.push(node)
    return this
  },
}

const pipe = fns => {
  return arg => fns.reduce((res, f) => f(res), arg)
}

const prop = key => val => node => ({ ...node, [key]: val })

const id = prop('id')
const tag = prop('tag')
const name = prop('name')
const klass = prop('class')

const file = pipe([tag('aFile'), klass('hello world')])

network
  .node(tag('foo'))
  .node(file, name('cool file'))
  .node(file, name('other file'))

console.log(network.nodes)

function deriveNetwork(bl) {
  // define rules for network definition as data
  // the network definition should be a document like structure
  // from the document structure we can bind the topology
  // then we can instantiate the things themselves
}
