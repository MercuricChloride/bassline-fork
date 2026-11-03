# image

An image of objects built from layers, and `bli`, a session on one.

An object is a node carrying layers: an Identity, slots, a function, a native, a cell, a doc. Sending a message hands it to each of an object's layers in turn and then to its `>>parent`, keeping `self`, so finding a name and inheriting from a prototype are the same delegation, and the root ends every chain. A reference names a place, which answers `(>>get)` and `(>>put V)`, so `set` takes names, paths, `(at …)`, `(layer …)` and any scheme an object answers `(>>resolve FORM)` for. `(>>send MSG REF)` is the one primitive form.

The image is everything reachable from the root. What happens to it is said as events and kept in a log, each entry chained to the one before and to the evaluation that caused it. A snapshot is the image written as one value, and opening an image is its last snapshot with the log replayed after it. Undo appends and never erases.

- `kernel.nim`: objects, layers, send, references, places, events
- `core.nim`: the forms an image boots with, and the schemes
- `library.nim` and `boot.bl`: numbers, values, control, introspection, `man`, the mezzanine and the manual
- `store.nim`: snapshots, written and read
- `history.nim`: the log, replay, undo, and the natives that read it
- `repl.nim`: `bli`

```sh
nim c -d:release -o:../bin/bli repl.nim   # from this directory
../bin/bli NAME                           # NAME.image.blb and NAME.log.blb here
nim c -r tests/twalkthrough.nim           # and tkernel, tstore, thistory, tlibrary
```

In a session, `(man)` lists every name and topic.
