# tinybl

A minimal yet pragmatic bassline implementation in nim.

The goal of tinybl is to be an approachable reference implementation of bassline while only being a few files. If you wanted to go fully barebones all you need to read is `ce.nim` and `raw.nim` but the other files offer some insight into what you practically want when it comes to a programmer api for values, which we build out in `values.nim` and then to make it cheaper at runtime to use, `memo.nim` adds on immutable values by reference + a mutable looking draft api. (Similar to immer.js for js readers).

Every value type is `Walkable`, and each one can be constructed through a `Builder[T]`. `Walkable` defines how a value is read, and is how ce encoding / printing is done. `Builder[T]` defines how a value is made. The ce reader and the text parser both hand their parts to a builder. A type that has static construction can be built via `ByType[T]`.

## Overview

### CE support

The file `ce.nim` implements the fundamental aspects of bassline values. The various decoding constraints, a resumable reader, and the two concepts for reading & constructing values defined in the previous section.

### Raw Values

One level above that is `raw.nim` which implements the simplest value structure as an object. It's extremely straightforward.

### Nicer Values

Above that, `values.nim` implements supporting data structures with `SortedTable`, `SortedSet`, and `BNum`, which are used to model bassline dicts, sets, and numbers respectively. This is then used by `ValueObj` to provide a nicer way to work with values at runtime.

### Bassline Text

The file `text.nim` implements a parser / printer for bassline text, which is a non canonical textual format that has a simple mapping to ce bytes. This can be used with any `Builder` to parse bassline text into instances of that particular type.

### Memoized Values

To make value comparison & construction cheap, `memo.nim` implements a `Cache` + `Memo` construct which are used for values that utilize structural sharing rather than directly holding their bytes. This is then utilized for `Draft` which defines a mutable feeling api on top of immutable structurally shared values.

### Events

Bassline programs are built from many parts that care about the same values, and none of them should be coupled to how, or whether, the others respond. The file `events.nim` defines a simple primitive for this. `Emitter[T]` can be used to emit values to every `Listener[T]` on it. Each `Listener` has its own inbox so emitting never waits on consumers, and to prevent unbounded growth slow listeners are closed if their inbox fills up. Similarly `Source` is an `Emitter` minus the capability to emit to others.

### Connections

The event construct in `events.nim` is extended in `net.nim` to allow for using network sockets as producers & consumers of values over a socket byte stream. The only bespoke construction this file offers is a simple batched writer to reduce syscall overhead when writing many small values and beyond that is relatively boring.
