
# Table of Contents

1.  [Introduction](#org2676478)
    1.  [TLDR](#org5c58aed)
    2.  [The Boogeyman](#org38b1454)
    3.  [Related Works & Important Differences](#org8f99ab7)
2.  [The Kernel](#org6b2c7e1)
    1.  [Utilities](#org9c45492)
    2.  [Words](#orgc88bc4e)
    3.  [Messages](#org89d171c)
3.  [Std Lib](#orgc8e7dbb)
    1.  [Communication Constructs](#org79bfa96)
    2.  [Transports](#org2d7c14c)



<a id="org2676478"></a>

# Introduction

This literate document contains the source code for the core of [Bassline](https://bassline.dev) v3.

It is designed to be hacked on and modified, so we encourage people to
read this!


<a id="org5c58aed"></a>

## TLDR

Bassline is built to make distributed programming dramatically simpler,
easier, and more flexible.

Specifically we are most interested in how this simplifies
decentralized distributed programming. An area that outside of
blockchains or very specific protocols is relatively starved.

Bassline offers a programming / epistemic model that allows arbitrary
programs & devices to collaborate and interact in an insanely small
package. It demands almost nothing from participants, is trivial to
support, and thrives in truly hetergenous settings.


<a id="org38b1454"></a>

## The Boogeyman

![img](book/evangel.jpeg)

Distributed programming has the same reputation as a boogeyman. It's
something that you check for under your bed at night. And it's
decentralized cousin is described similarly to the devil or an eldritch
horror.

The church of k8s and the related devops sects preach the dangers of
this "beast". They offer salvation through system images,
microservices, monoliths, and more specifications. Yet none of these
fully solve the problem.

We don't believe distributed programming is a boogeyman, we think it's
just misunderstood. The biggest misunderstanding, we believe, is the
extreme cost uncontrolled proliferation of non-local ontology.

In local programming we commonly build programs in terms of "things"
and what they mean. It is an act of building a local ontology to
express the program we want. But the issue is that when switching to a
distributed setting, there are no "things". A distributed program is
just a program running on a single machine that talks with the outside
world via local affordances. There is no "message broker", there is
locally received messages that I locally assign to be coming from a
message broker.

Bassline doesn't fight this, in fact we lean into it fully. We
acknowledge that outside of our local programs, we can't know anything
concrete, we can only observe messages. There is natural information
asymmetry between "what I know currently" and "everything else".

So rather than build from "things", we build from communcation, with
the commitment being we do not build from things that aren't also
available in the most extreme p2p setting you can imagine. The result
is a system that is decentralized & distributed by construction, yet
totally ontologically sovereign.


<a id="org8f99ab7"></a>

## Related Works & Important Differences

This isn't the first system to focus on communication. But we believe
we expand on some of the ideas in subtle but important ways.

Things like the actor model, ocap systems, etc are much less
"thing-oriented" than other systems. But they still make some global
ontological commitments for the kind of shape the system has.

The tricky thing is that these commitments to the system shape mandate
their supporting constructs since the worldview & model requires them.


### TODO Expand on the issues of blessed addressing & identity

-   Identity is a local judgement
-   Addressing requires specific topologies & protocols
-   Bassline doesn't preclude addressing or identity, we just don't
    build it in the foundation, since it doesn't hold in all settings.
-   This means that in Bassline you can use whatever you want / need,
    because we don't bless any kind of communication / connection.


### TODO Expand on the issues of symmetric communication

-   The ability to receive information doesn't imply the ability to respond
-   The ability to respond to something doesn't imply the ability to be receive
-   These become more powerful when you have anonymous communication and
    no standard identity


### TODO Expand on the tyranny of names

-   anonymous messages and caps gives us implicit / tacit apis
-   Removes the concept of an "endpoint" because it's not there


<a id="org6b2c7e1"></a>

# The Kernel

The kernel is extremely small. It's a narrow waist of 2 constructs
that all our local programs can easily project into.

The messages, which are containers that allow `words` to be named. As
well as `words`, which are containers that give us a way of carrying
data + an opaque referent we can send messages.

If you were building out a fresh implementation of Bassline in another
language, you would only have to implement these constructs, then just
define projections to and from these forms.

For each concept we introduce we will separate the abstract idea from
the concrete implementation used in this book. The abstract layer
explains what shape of thing we are modeling. The concrete layer shows
one minimal JavaScript realization of that shape.


<a id="org9c45492"></a>

## Utilities

We keep it minimal for the utilities. We export a few factories for
words, nouns, and verbs. We also include a recognition vocabulary for
Bassline terms.

    export const MSG = Symbol.for('$$BASSLINE_MSG$$')
    export const WORD = Symbol.for('$$BASSLINE_WORD$$')
    
    export const is = {
      null: v => v === null,
      undefined: v => v === undefined,
      nan: v => Number.isNaN(v),
    
      number: v => typeof v === 'number' && !is.nan(v),
      string: v => typeof v === 'string',
      boolean: v => typeof v === 'boolean',
      array: v => Array.isArray(v),
    
      object: v => typeof v === 'object' && !is.null(v) && !is.array(v),
      fn: v => typeof v === 'function',
    
      word: v => is.object(v) && v[WORD],
      msg: v => is.object(v) && v[MSG],
      nbound: v => is.word(v) && is.noun(v.noun),
      vbound: v => is.word(v) && is.verb(v.verb),
      bound: v => is.nbound(v) || is.vbound(v),
    
      nil: v => is.null(v) || is.undefined(v) || is.nan(v),
      scalar: v => is.number(v) || is.string(v) || is.null(v) || is.boolean(v),
      noun: v =>
        is.scalar(v) || is.object(v) || is.array(v) || is.word(v) || is.msg(v),
      verb: v => is.fn(v),
    }
    
    export function word(definition) { return new Word(definition) }
    export function noun(value) { return new Word({ noun: value }) }
    export function verb(value) { return new Word({ verb: value })}
    export function msg(dict) { return new Msg(dict) }


<a id="orgc88bc4e"></a>

## Words


### Abstractly

A `word` is a container for two things:

1.  An early bound `noun`
    
    A word's noun represents data commited upon creation. It can be
    either undefined, null, number, string, array, record, a word, or a
    message.

2.  A late bound `verb`
    
    A word's verb is a uni-directional communication affordance on a
    word. It must be given a message and lets us communicate
    communication affordances alongside data.


### Concretely

A word implementation is pretty simple. It's just an object with a
noun & verb property. The `noun` can be any bassline value, and the `verb`
can be unary procedure that takes a message.

In JS we use the symbol `WORD` to detect when something is a WORD so
custom implementations can be built and recognized.

    export class Word {
      get [WORD]() { return true }
      constructor(definition = {}) {
        if (is.fn(definition)) definition(this)
        else if (is.object(definition)) this.def(definition)
        else throw new Error(`Invalid word definition: ${definition}`)
      }
      def({ noun, verb } = {}) {
        if (noun !== undefined) this.noun = noun
        if (verb !== undefined) this.verb = verb
        return this
      }
    }


<a id="org89d171c"></a>

## Messages


### Abstractly

A `message` is a dictionary from a spelling to a `word`.

All keys of a `message` must be strings, and all values must be `words`.

A message is:

-   Data
-   Anonymous
-   Sovereign
-   Portable and easy to share
-   Free of "meta-data"
-   Free of a priveledged meaning

Let's expand on these a bit

1.  They are data

    Messages are fundamentally data. They are values, and are easily
    shared over the wire, stored, etc.
    
    They do not have a declared schema other than being dictionaries of
    words.
    
    Since they are data you are free to be replicated and shared as you
    wish.

2.  They are globally anonymous

    There is no global way of addressing a message or a word. So we never
    say: "this message" in a universal manner.
    
    A message can be bound to a name or address locally, giving us a way
    to refer to it. But that is a property of the binding, not of the
    message.
    
    You also might have a way of identifying a message such as an id or a
    hash. But this not fundamental to a message, it's just an
    interpretation of it's words.

3.  Messages are sovereign

    **This is an important point, so listen up!**
    
    Messages are ontologically sovereign. Meaning they have no special
    meaning other than the meaning you choose to assign to it.
    
    As such, when receiving a message that message is YOURS. It's
    "meaning" and what it entails is completely decided by you. A message
    can contain information to make this process easier, but a message
    doesn't have an absolutely true interpretation.
    
    This is why there is no "metadata" for a message. Because metadata
    blesses a canonical form of what is the "content" and what is "about
    the message". This violates the ontological sovereignty of a message.
    
    As such any "metadata" kind of things belong in the message directly
    like any other data. The "meta-ness" of the data is the choice of the
    receiver of the message.


### Concretely

    export class Msg {
      get [MSG]() { return true }
      words = Object.create(null)
      constructor(dict = {}) { this.defineWords(dict) }
      word(aKey) {
        if (!this.words[aKey]) this.words[aKey] = word()
        return this.words[aKey]
      }
      define(aKey, aDef) {
        if (is.word(aDef)) { this.words[aKey] = aDef }
        else { this.word(aKey).def(aDef) }
        return this
      }
      defineWords(dict) {
        for (const [k, v] of Object.entries(dict)) this.define(k, v)
        return this
      }
      get entries() { return Object.entries(this.words) }
      get nouns() {
        return Object.fromEntries(
          this.entries.filter(([_k, v]) => is.nbound(v)).map(([k, v]) => [k, v.noun])
        )
      }
      get verbs() {
        return Object.fromEntries(
          this.entries
            .filter(([_k, v]) => is.vbound(v))
            .map(([k, v]) => [k, v.verb])
        )
      }
    }


<a id="orgc8e7dbb"></a>

# Std Lib

Now that we have words & messages built out, we can start defining some
useful machinery.


<a id="org79bfa96"></a>

## Communication Constructs


### Abstractly

Communication in Bassline bootstraps from a single primitive: `send`.

`send` is an opaque procedure that takes a single message argument. This
is what a word can carry as it's `verb`.

So long as `send` is opaque, it allows our programs to work in arbitrary
environments since they won't depend on what they are talking with,
addressing schemes, or the concrete existence of any participant.

An important thing to note is in order for something to be a `send`, it
must be an opaque way of speaking out. Because this is the most we can
commit to in a distributed setting without leaking commitments that
don't hold.

As such, something like `recv` cannot be a `send`. I cannot give you a way
of receiving a message because receiving a message is always through
your own local affordances. The only thing we can do in a distributed
setting, is communicate ways of communicating through an existing
medium.


### Concretely

The communication constructs in Bassline are implemented as normal
runtime objects that support being projected into a word or a message.

The reason we say either or, is because a word represents the smallest
communication surface. It's just some data alongside a way to speak to
"it".

Should there be more interesting components than just a `send`, then you
can also project it into the message.

1.  Port

    A port is a minimal surface that implements buffered communication.
    
    It implements `send` and can be projected as a message.
    
    It's important to note that there is no builtin lifecycle propagation
    or buffering with these ports. It's trivial to include as a dialect,
    but is leaky to include. This is because knowing how to "send" to
    something, doesn't mean we know it's alive, or that they can
    communicate with us.
    
    Senders are not notified when they `send` to a closed port. This ensures neither side requires knowledge
    of the other's state / status without the other side explicitly
    sharing this, maintaining the sovereignty of the caps.
    
    You should still communicate when you die though but we can't force
    you. "#messaging-in-my-grave"
    
    1.  Lifecycle Controller
    
        Internally a port does need to track lifecycle, since ports are often
        what we shove in front of actual transports and they are naturally
        async. This class implements this from an AbortController.
        
        The controller itself is capable of being represented as a word as
        well.
        
            export class UseAfterClose extends Error {
              constructor(aController) {
                super('attempted to use a controller after it has been closed')
                this.controller = aController
              }
            }
            
            export class Controller {
              controller = new AbortController()
              get signal() { return this.controller.signal }
              get closed() { return this.signal.aborted }
              assertOpen() { if (this.closed) throw new UseAfterClose(this) }
              close(reason = 'closed') { if (!this.closed) this.controller.abort(reason) }
            
              onClose(fn, { signal } = {}) {
                if (this.closed) fn()
                else this.signal.addEventListener('abort', fn, { once: true, signal })
                return this
              }
              asWord() {
                return word({
                  noun: this.closed,
                  verb: () => this.close(),
                })
              }
            }
    
    2.  Port implementation
    
        The port implementation is rather simple.
        
        It maintains a buffer for messages, and a queue of promises to
        resolve. We can give the buffer a fixed capacity, in which it will
        act as a sliding buffer, dropping the oldest messages.  Or if we give
        it a capacity of 0, it will not buffer any messages, requiring a
        listener actively be waiting for a message, dropping all others.
        
        If the port has been closed, recv yields `undefined` indicating
        consumption should be stopped.
        
            export class Port {
              buffer = []
              waiters = []
              ctl = new Controller()
              get isBounded() { return this.size !== Infinity }
              get anyWaiting() { return this.waiters.length > 0 }
              get overflowing() { return this.buffer.length >= this.size }
              get shouldBuffer() { return this.size > 0 }
              get closed() { return this.ctl.closed }
              close(reason) { this.ctl.close(reason) }
              constructor(size = Infinity) {
                super()
                this.size = size
                this.ctl.onClose(() => {
                  for (const waiter of this.waiters) waiter(undefined)
                  this.waiters.length = 0
                })
              }
              async recv() {
                if (this.buffer.length > 0) return this.buffer.shift()
                if (this.closed) return undefined
                return new Promise(resolve => this.waiters.push(resolve))
              }
              send(aMsg) {
                if (is.undefined(aMsg) || this.closed) return
                if (this.anyWaiting) return this.waiters.shift()(aMsg)
                if (this.overflowing) this.buffer.shift()
                if (this.shouldBuffer) this.buffer.push(aMsg)
              }
              async consume(aWord) {
                while (true) {
                  const msg = await this.recv()
                  if (is.undefined(msg)) break
                  aWord.verb(msg)
                }
              }
              toWord() {
                return word({
                  noun: {
                    size: this.isBounded ? this.size : null,
                    bounded: this.isBounded,
                  },
                  verb: aMsg => this.send(aMsg),
                })
              }
            }

2.  Propagator

    A propagator let's us define something that can selectively propagate
    interesting messages to a set of `words`.
    
    When constructing a propagator, you provide a propagation function,
    this takes 2 arguments: `aMsg` and `send`. `send` will propagate out to all
    targets, allowing us to propagate multiple times per invocation.
    
    If you don't provide a propagator, it will behave as a relay point,
    and will just pass messages through to the targets.
    
    You can also use a propagator like a reactive procedure by just not
    calling propagate in the body, and using it as a way of running a
    function.
    
    When we project a propagator to a word, it is behaviorally identical
    to port. But unlike `port`, a propagator doesn't buffer. It eagerly does
    work.
    
    Cycles are supported and encouraged, just make sure you correctly
    setup your propagators to correctly attenuate.
    
        export class Propagator {
          constructor(
            action = (aMsg, send) => send(aMsg)
          ) {
            this.targets = new Set()
            this.action = action
          }
          target(...words) {
            for (const aWord of words) {
              if (!is.word(aWord)) throw new Error(`expected word: ${aWord}`)
              if (!is.vbound(aWord)) throw new Error(`expected vbound word: ${aWord}`)
              this.targets.add(aWord)
            }
            return () => {
              for (const aWord of words) this.targets.delete(aWord)
            }
          }
          emit(aMsg) { for (const w of this.targets) w.verb(aMsg) }
          send(aMsg) { this.action(aMsg, v => this.emit(v)) }
          toWord() { return verb(aMsg => this.send(aMsg)) }
        }

3.  TODO Purgatory

    These things i'm probably going to remove or change.
    
    1.  TODO Cell
    
        Goose note: this is old and uses the older api, i'm debating how I
        want to go about building this specifically, since there are some
        designs that might be better.
        
        This is almost identical to `propagator`. The only difference is the
        function is a bit different, and it closes over some private state.
        
        The `merge` function takes 3 arguments:
        
        1.  `current`
            The current value of the state
        2.  `incoming`
            The received message
        3.  `update`
            A function that updates state and propagates the new value.
        
        When building cells, it's best to ensure they are Associative,
        Commutative, and Idempotent. This let's any cell behave as a CRDT with caps!
        
        **NOTE: Probably want to make the state a message, but it's a wip**
        
            export class Cell extends Propagator {
              state = new Set()
              action = (current, incoming, update)
              send(aMsg) {
                this.action(this.state, aMsg, v => {
                  this.state = v
                  this.emit(v)
                })
              }
            }
            
            export function cell(merge, init) {
              const description = 'I am a cell. I am a propagator with state'
              let current = init
              const [m, to] = propagator((incoming, propagate) => {
                merge(current, incoming, value => {
                  current = value
                  propagate(value)
                })
              })
              m.merge({ description })
              return [m, { to, value: () => current }]
            }
    
    2.  TODO Net
    
        Goose note: I'm probably going to remove this, it's honestly not really
        that interesting.
        
        Current ports look like "point-to-point" communication, however in
        Bassline we don't talk to "something", we observe information from our
        perspective, and invoke caps through opaque handles. We can exploit
        this fact to build a `net`.
        
        A `net` is a local structure that gives us ports backed by any number of
        things.  Meaning that we build a compound communication interface
        without the consumers or producers ever knowing directly, since it has
        the same caps as a port.
        
        This structure is a decent showcase that "participant" is a very loose
        term in Bassline.
        
            export function net() {
              const description = `\
            I am a net.
            I implement seamless multi-party communication.`
              const ports = new Set()
              const netm = new Msg()
            
              netm.defaults({ description }).grantCaps({
                send: msg => ports.forEach(p => p.send(msg)),
                close: netm.close,
              })
            
              const join = size => {
                const [fromNet, recv] = port(size)
                const toNet = fromNet.copy().grantCaps({
                  send: msg => {
                    for (const p of ports) {
                      if (p === fromNet) continue
                      p.send(msg)
                    }
                  },
                })
            
                ports.add(fromNet)
                fromNet
                  .closedBy(netm)
                  .closeGroup(toNet)
                  .onClose(() => ports.delete(fromNet))
            
                return [toNet, recv]
              }
            
              return [netm, join]
            }


<a id="org2d7c14c"></a>

## Transports

As above, it helps to separate the abstract role of a transport from
the concrete transport used in this book.

I need to update this prose below, because the wire conversion stuff
is a good opportunity to highlight the notion of lowering and lifting
messages.


### TODO Abstractly

A transport adapts some external medium into local communication
capabilities. This matters because the programming model should not
change just because information crossed a process boundary, a machine
boundary, or a device boundary. Local and non-local communication
differ in mechanics, but they should not require different conceptual
tools.


### Concretely

Every transport produces a port as we defined above. Internally however
they handle the marshalling and unmarshalling of the data coming off
the wire.

The transports do not deal with storing of the word's verbs, instead
before something goes over the wire or comes off the wire, you should
use a reification construct to lower the message into interpretable
data.

The only difference between any of these is the medium underneath and
whether that medium carries raw bytes or discrete messages.

Byte transports (TCP sockets, stdio, serial) carry raw chunks. They
need a framing layer to delimit and parse messages. Message transports
(WebSocket, WebWorker/MessagePort) carry discrete messages natively
and skip framing entirely.

1.  Framing

    Framing is separated from any specific transport.
    
    The frame will parse those strings into a buffer, forwarding messages
    using the vbound `word` we provide upon construction.
    
    On error it will `console.error` and throw the error. Though this can be
    replaced later.
    
    One input chunk may produce zero or many messages.
    
    `format` is a stateless function that serializes a message as a JSON line. This
    is used on the outgoing side to serialize before writing.
    
        import { is, msg } from '../bassline.js'
        
        export class JSONLFrame {
          buffer = ''
          constructor(aTarget) { this.target = aTarget }
          readChunk(aString) {
            if (!is.string(aString)) return
            buffer += aString
            let nl
            while ((nl = buffer.indexOf('\n')) !== -1) {
              const line = buffer.slice(0, nl)
              buffer = buffer.slice(nl + 1)
              if (!line) continue
              try {
                const raw = JSON.parse(line)
                this.target.verb(msg(raw))
              } catch (e) { this.onError(e) }
            }
          }
          onError(e) {
            console.error('Frame parse error: ', e)
            throw e
          }
          static format(aMsg) {
            //TODO: Make this work properly
            return JSON.stringify(aMsg) + '\n'
          }
        }
        export default function(aTarget) { return new JSONLFrame(aTarget) }

2.  Socket

    A socket is a byte transport. `fromSocket` creates a raw port for byte
    chunks, a message port for parsed messages, and bridges them through
    `frame.read`. Outgoing messages are formatted and written directly to
    the socket.
    
        import net from 'node:net'
        import { msg, verb } from "@bassline/core"
        import { port } from '../comms.js'
        import defaultFrame from '../frame/jsonl.js'
        
        export function fromSocket(socket, createFrame = defaultFrame) {
          const outgoing = verb(m => socket.write(frame.format(m)))
          const incoming = new Port()
          const frame = createFrame(incoming.toWord())
        
          incoming.ctl.onClose(() => socket.destroy())
          socket.on('data', chunk => frame.readChunk(chunk.toString()))
          socket.on('close', outgoing.close)
          socket.on('end', outgoing.close)
          socket.on('error', outgoing.close)
        
          return [incoming, outgoing]
        }
        
        export function connect(options = {}, createFrame = defaultFrame) {
          return fromSocket(net.createConnection(options), frame)
        }

3.  Serving (TCP)

    A TCP server listens on a socket and produces a port of
    connections. Each connection is itself a port, produced by
    `fromSocket`.
    
        import nodeNet from 'node:net'
        import { fromSocket } from '../transports/socket.js'
        import { msg } from '../bassline.js'
        import defaultFrame from '../frame/jsonl.js'
        
        const description = `\
        I am a server.
        I handle incoming connections as ports.`
        
        export function serve(onConnect, options = {}, frame = defaultFrame) {
          const m = msg().merge({ description, options })
        
          const server = nodeNet.createServer(socket => {
            const [client, recv] = fromSocket(socket, frame)
            client.closedBy(m)
            onConnect([client, recv])
          })
        
          m
            .grantCaps({ close: m.close })
            .closes(server)
        
          server.listen(options)
          server.on('close', m.close)
          server.on('error', m.close)
        
          return [m, server]
        }

4.  Serving (WebSocket)

    A WebSocket server wraps an existing `WebSocketServer` instance and
    produces a port of connections, matching the TCP serve API shape. The
    caller brings their own `WebSocketServer` — no `ws` dependency in
    core.
    
        import { fromWebSocket } from '../transports/websocket.js'
        import { msg } from '../bassline.js'
        
        const description = `\
        I am a web socket server.
        I behave similar to a normal server,
        but over web sockets. Go figure!`
        
        export function serve(wss, onConnect) {
          const m = msg()
            .merge({ description })
            .closes(wss)
        
          wss.on('connection', ws => {
            const [client, recv] = fromWebSocket(ws)
            client.closedBy(m)
            onConnect([client, recv])
          })
        
          m.grantCaps({ close: m.close })
          wss.on('close', m.close)
          wss.on('error', m.close)
        
          return [m, wss]
        }

5.  WebSocket

    A WebSocket is a message transport. Each `ws.send()` is one discrete
    message, so no framing is needed. This works in the browser with
    native `WebSocket`, in Node.js with the `ws` package, and for
    `RTCDataChannel` since it has the same event interface.
    
        import { port, msg } from '../bassline.js'
        
        const description = `I am a web socket.`
        
        export function fromWebSocket(ws) {
          const outgoing = msg()
            .merge({ description })
          const [msgs, recv] = port()
          ws.addEventListener('message', e => {
            try {
              msgs.send(msg().merge(JSON.parse(e.data)))
            } catch (e) {
              console.error('failed to parse: ', e)
            }
          })
        
          ws.addEventListener('close', outgoing.close)
          ws.addEventListener('error', outgoing.close)
        
          outgoing
            .closes(msgs, ws)
            .grantCaps({
              send: m => ws.send(JSON.stringify(m.data)),
              close: outgoing.close,
            })
        
          return [outgoing, recv]
        }

6.  WebWorker

    A `MessagePort` is a message transport that uses structured
    clone. Objects cross the boundary without serialization. Works with
    `Worker`, `MessagePort`, `SharedWorker.port`, and `BroadcastChannel`.
    
        import { msg, port } from '../bassline.js'
        
        const description = 'I am a message port.'
        export function fromPort(messagePort) {
          const outgoing = msg().merge({ description })
          const [msgs, recv] = port()
          messagePort.onmessage = e => msgs.send(msg().merge(e.data))
          messagePort.onmessageerror = outgoing.close
        
          outgoing.closes(msgs, messagePort).grantCaps({
            send: m => messagePort.postMessage(m.data),
            close: outgoing.close,
          })
          return [outgoing, recv]
        }

7.  Stdio

    Stdio is a byte transport, like TCP, and uses framing internally to
    produce a port of messages.
    
        import readline from 'node:readline'
        import { port, msg } from '../bassline.js'
        import defaultFrame from '../frame/jsonl.js'
        
        const description = 'I am a stdio port'
        
        export function fromStdio(frame = defaultFrame) {
          const rl = readline.createInterface({ input: process.stdin })
        
          const [reader, onRead] = frame.reader()
          const [msgs, recv] = port()
        
          onRead(v => msgs.send(v))
        
          const outgoing = msg()
            .merge({ description })
            .grantCaps({
              send: m => process.stdout.write(frame.format(m)),
              close: () => outgoing.close()
            })
            .closes(msgs, rl, reader)
        
          rl.on('line', line => reader.send(msg().merge({ scalar: line + '\n' })))
          rl.on('close', () => outgoing.close())
          return [outgoing, recv]
        }
    
    <footer class="book-footer">
      <div class="footer-links">
        <a href="https://bassline.dev">bassline.dev</a>
        <span class="separator">&middot;</span>
        <a href="https://github.com/Bassline-Org/bassline">GitHub</a>
      </div>
      <p class="footer-license">AGPLv3</p>
    </footer>

