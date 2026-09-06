// @ts-check

// Node transport for a self-framing stream of bassline values. Not part of the
// portable core surface (`@bassline/core/data`) — this pulls in `node:stream`
// and `node:net`, so it is its own opt-in entry point.
//
// The framing and reassembly are core's Decoder / ValueView; this is only the
// Node glue: byte streams in and out, and a small TCP adapter.

export * from './transform.js'
export * from './socket.js'
export * from './server.js'
