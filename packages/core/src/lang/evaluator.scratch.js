// Interactive scratch for the evaluator. Run with:
//   node packages/core/src/lang/evaluator.scratch.js

import { makeEvaluator } from './evaluator.js'
import { print } from '../text/index.js'

const ev = makeEvaluator()

const run = src => {
  console.log('> ' + src)
  const res = ev.load(src)
  console.log(print(res), '\n================')
  return res
}

run('`<set {x: 10}>') // bind x = 10
run('`<echo `x>') // 10   (marked symbol: deref)
run('`<echo x>') // x    (unmarked: literal)
run('`<echo `<+ `x 5>>') // 15   (marked argument evaluated)
run('`<fn inc [n] <+ `n 1>>') // define inc
run('`<inc 5>') // 6
run('`<apply inc [`x]>') // 11
run('`<apply + [x x]>') // 20
run('`<apply * [x x]>') // 100
run('`<apply / [100 x]>') // 10
run('`inc')
run('inc')

// a sheet: literal cells, formula cells with references, and a reference cycle
//run('`<sheet <cell A1 1> <cell A2 `<+ `A1 1>> <cell A3 `<+ `A1 `A2>>>')
//run('`<sheet <cell A `B> <cell B `A>>')

//console.log('env:', print(ev.toBassline()))
console.log('transcript:', ev.getTranscript())
