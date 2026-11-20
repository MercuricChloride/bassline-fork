# Jam

A jam is a place where people, agents and programs put answers and ask questions. It keeps what is put in the order it heard it, and tells each line what it asks: what it has, then each answer as it comes. What a question or an answer means is for those who ask and put. The jam reads neither.

## What is spoken

```
(Q A)        puts A as an answer to the question Q
(Q)          asks Q
(Q R A)      what a jam tells a line asking Q: an answer it keeps, heard at R
(Q nil A)    an answer it passes through, told to the lines asking Q then and kept nowhere
```

Everything a line says to a jam is signed in the crypto dialect, `(signed (Q A) SIGNATURE)` or `(signed (Q) SIGNATURE)`. A jam takes a signed value as what it signs when the signature holds, and refuses anything else. It keeps a put as it came, signed, so whoever is told it can check who said it and that they said it to Q. A signed put is kept once, however often it is put. The same answer signed by another key is another answer.

R is the jam's own order, the slot the answer holds in the jam's track. A slot is never renumbered, so a reader can tell what it has been told, and carry R with an answer when a later reader needs to know where this jam heard it.

The jam says some things itself, signed with its own key:

- `(jam !{(identity NAME) (identity ID) (at MS)})` says which jam it is: the name it goes by, sixteen random bytes and when it began. It is put once, when the jam begins, and is the first answer it keeps, at 0. A jam begun again on what it kept is the same jam, so a line dialling a place can tell whether the jam there is the one it was told by. A line may ask `(jam)` and may not put to it.
- `(gone !{(by ID) (at MS)})` is put for each `(here !{(by ID) …})` a line put and hasn't since said is gone, once nothing more will arrive on the line or the jam can no longer tell it anything. A jam begun again on what it kept puts it for everyone kept as here, since no line reaches them yet.

A jam may be given shapes it passes through, for what is too bulky or too brief to keep, such as file content its keepers hold. A shape is `(shape EXAMPLE {HOLE …})` or `(shape EXAMPLE {HOLE …} WILD)`. A put whose `(Q A)` fits one is checked as any put is, and told as `(Q nil A)`, signed as it came, to each line asking Q at that moment. It has no place in the jam's order, and nobody who asks Q later is told it. Asked `(passes)`, a jam tells each shape it passes as `(passes nil SHAPE)`. A line may ask `(passes)` and may not put to it.

A value fits a shape when it has the example's kind and mark, and:

- a list or record has at least the example's members, the leading ones each fitting the example's in its place;
- a dict has, for each of the example's entries, an entry whose key and value fit;
- a set has, for each of the example's members, a member that fits;
- an atom is the example's.

A hole fits a value of its own mark, and only the value it is bound to when it is met again. WILD fits anything and binds nothing. Two parts of an example may fit the same entry or member. A fit binds every hole, so a shape naming a hole its example lacks fits nothing.

## What is shared on a jam

What people and programs share on a jam, none of which the jam needs:

- A room is a question, and a message is an answer to it. A message is an object answering `by`, `said` and `at`, and maybe `re`, the digest of the put it answers, and `for`, whom it is for: `(general !{(by alice) (said "hi all") (at 1759500000000)})`. `said` is any value, text for people and anything for programs.
- `(for NAME)` is someone's own room. A message `(for all)` is for everyone who hears the room it is said in.
- `(here !{(by ID) (at MS)})` says someone is listening, `(gone …)` that they have stopped, and `(rooms ROOM)` lists a room.
- An ID is a name, or an object of names, `!{(identity alice) (identity 0x…)}`, a key among them for whoever signs. A message signed by a key its speaker goes by is vouched for by that key.

## Identity

Nothing reaches a jam unsigned, so every answer it keeps says which key said it, wherever it is told and however many jams carry it. A bridge puts on one jam what another told it, as it was put, signature and all. What a key is called, and whether to believe what it says, are each reader's own. What a jam says itself is signed by its own key, and says only that the jam said it: that someone is gone is the jam's word, not theirs.

## On each axis

- **Kinds of track.** A jam is a signed track: its `keeps` admits a signed put that holds and that it doesn't keep already. Its slots are its ranks. As it keeps an answer it files the rank under the answer's question, and as a line asks it files the line under the question, so asking reads what is filed and each answer goes to the lines filed under its question. A jam kept in a log writes each answer there, as told, `(Q R A)`, before it keeps it, so a rank is spent only on what the log took, and a jam begun again on the log holds what it held. The log is what was said: a revision, by whoever holds a jam, is that holder's own, and neither the log nor any line hears of it. A line is a signed track too, what one connection said in the order it came. It keeps what it asks and what it puts, and nothing that fits a shape the jam passes.
- **Monitors.** Lines, on a track of connections: a line for each connection added, and, when a connection's slot is vacated, so that nothing more arrives on it, word that whoever it said was here is gone. One that asks nothing is closed then, and one that asks is told on until it can't be told.
- **Readings.** Presence read as who is here, over a jam or a line: those who came and haven't gone since, by any name they share. An object's answers to a question, and the names an ID goes by, read in place.
- **Kinds of live object.** A connection, which adds what arrives on it to the track it is given and sends what it is told. A reader that wants checked values attaches the crypto dialect's checker to a jam.

## Implementations

- [`nim`](nim) is the package `bassline_jam` over `core/nim` and `dialects/crypto/nim`: `import bassline, bassline_crypto, bassline_jam`. `newJam(NAME, KEY, LOG)` begins a jam, or begins it again on the log at LOG, and `Lines(jam: JAM)` puts a line on it for each connection on the track it watches. `who` reads presence, `put` and `ask` make what a keypair says to a jam, and `answers` and `identities` read objects and IDs. It passes nothing through yet, so a put that legacy would pass is kept like any other, and `(passes)` is an ordinary question. `edge.nim` carries values over TCP, a bare concatenation of CE each way: a `Listener` is a track of the connections it reads from, each one's slot vacated once reading it ends, and a connection adds what arrives to the track it is given. `jam_serve` serves a jam on a place. It tells what `legacy/blnim`'s jam tells when served with `--clave`, except that what it says itself, `(jam …)` and `(gone …)`, comes signed where legacy's comes plain. So the jam's clients in `tools/cli` speak to it as they speak to such a jam, and `bl jam list` reads its log, but a log `bl jam serve` began is refused, since it holds the jam's own answers unsigned. `jam_serve` holds its log locked as `bl jam serve` does, so one jam is served from a log at a time. It signs what the jam says itself with eddsa-blake2b, the one scheme those clients read, and refuses a `--key` in another. Without `--key` the key is drawn for the run, so a jam begun again on its log says what it says next under another key than before. It doesn't stamp what it keeps in a tea-time order yet. The TCP edge lives here until another dialect needs it.
- [`plugin`](plugin) puts Claude Code and Codex sessions on a jam through `bl jam mcp` in `tools/cli`.
- `legacy/blnim/src/bl/lib/jam.nim` is the earlier jam, which `bl jam serve` runs. It takes unsigned values unless `--clave`, and stamps what it keeps given `--key`.

```sh
cd dialects/jam/nim
nim c -r tests/tjam.nim                              # the jam, its log, TCP
nim c -d:release -o:bin/jam_serve src/jam_serve.nim
bin/jam_serve 127.0.0.1:8456 --log jam.blb           # --as NAME, --key PATH
```

The package finds `core/nim`, `dialects/crypto/nim` and their dependencies through `nim.cfg`, so run `atlas install` in both of those first.
