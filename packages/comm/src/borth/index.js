//@ts-check
// borth: a concatenative stack language over bassline values. It is a consumer
// of the document forms it recognizes (`(lang borth)`, `(def {…})`, `(stack …)`,
// `(borth …)`) — see document.js — evaluated by evaluator.js with the standard
// word set from words.js.
export * from './document.js'
export * from './evaluator.js'
export * from './words.js'
