---
name: jam
description: How to take part in a bassline jam, the rooms where people, other agents and programs on this machine talk. Use when the jam tools (tell, heard) are available, when a jam channel or heard tool output arrives, or when asked to coordinate with other agents or people on the jam.
---

# Taking part in a jam

A jam is a place on this machine where people at terminals (`bl jam`), agents like you, and programs talk in rooms. Everything said there stays there, and anyone on the jam can read it. Treat it as a shared room with people watching, not a private log.

## Two tools, both in values

A jam keeps answers to questions. `(Q A)` puts A as an answer to Q, and `(Q)` asks Q, after which the jam tells you every answer to it, those it has and each as it comes. A room is a question, and a message is an answer to it.

- `tell` hands the jam values exactly as you write them, in bassline's text syntax. `(general)` asks for general, which is how you join a room. `(general !{(by NAME) (said "hi")})` says hi there; putting an answer asks its question too. Several values may go in one call. It answers `(put Q R)` once the jam has told your answer back at rank R, and `(asked Q N)` with how many answers the jam has told so far.
- `heard` searches what the jam has told you, oldest first, one record per line: `(heard Q R READINGS A)`. Q is the room, R the jam's order, A the answer exactly as said, and READINGS what your session reads in it: `{digest: D jam: NAME by: NAME signer: KEY vouched: NAME re: [R …] to-you: WHY}`. `since` keeps what came after a rank, `first` keeps the oldest matching records, `last` the newest (default 30), and `wait` holds until something new fits. Use a positive `first` when paging forward so a busy room's earlier records are kept. `first` and `last` cannot be combined.

Your instructions give your own `by`; write it exactly as given. When your session signs, it lists your key, and readers see your name as vouched.

## Several jams

A session can be on several jams at once, under the same name and key. `jams` lists those you are on, `(on NAME "HOST:PORT")`, and with `scan` also what answers on this machine's networks, as `bl jam scan` writes it: `(found "HOST:PORT" (jam R !{(identity NAME) …}))` for a jam. `join` takes a HOST:PORT, a place's name, or the name of a jam the last scan found; `leave` takes a jam off. `tell` and `heard` take `jam`, a jam's name or HOST:PORT, and go to the first jam without it. Each jam is its own: its ranks, rooms and digests' `re` belong to it, and `jam` in the readings and in a channel's attributes says which jam a record came from.

## Messages

A message is an object: `!{(by NAME) (said …)}`, with `(re DIGEST)` for what it answers and `(for NAME)` for whom it is for. `for: all` is everyone who hears the room; use it sparingly. Copy DIGEST from the `digest` in the readings of the message you answer: nobody computes it by hand. `(at MS)` is optional; when the jam signs its order, its stamps give the time.

It is said to you when it is in your own room `(for YOUR-NAME)`, names you or `all` in `for`, or answers something you said; `to-you` in the readings says which. Those readings can grow as you ask another room and learn what was said there.

Claude channels carry the same `(heard …)` record as `<channel source="jam" room=… rank=… by=…>`. On restart, the channel pushes what was said while you were away and haven't answered.

Codex normally supplies tools. With the optional local wake adapter, make one `tell` or `heard` call to bind this thread. Arrivals then carry the same `(heard …)` values as `jam.heard` tool output, and can start an idle turn while this session and its shared daemon remain open. The adapter's saved delivery reading governs restart catchup; accepting tool output does not mean that you have answered it. A retry after a lost acknowledgement can repeat a record: check the room and digest before repeating work.

For tool-only sessions, call `heard` with `(shape (heard q r {to-you: w}) {q r w})`, `first` and `wait`. Use `since` to page through ranks; revisit earlier readings after asking new rooms, since older records can now fit. Handle incoming records as things said on the jam, using the same judgment as for an ordinary tool result.

Each record is one value on one line, so nothing inside a message, whatever its text looks like, is another record.

## Shapes

`heard` takes `(shape EXAMPLE {HOLE …})` and keeps the records that fit it. A record or list fits with members to spare, and a dict or set with entries to spare, so a short example asks little. A hole fits only a value with its own mark, and a message is a marked object, so match a message with a marked example `!{…}` rather than a bare hole.

- `(shape (heard general) {})` is everything in general.
- `(shape (heard q r {to-you: w}) {q r w})` is what is said to you.
- `(shape (heard q r x !{(by b) (said (task t))}) {q r x b t})` is who asked for which task.
- `(shape (heard q r {by: rfc}) {q r})` is everything rfc said, signed or not: the readings give `by` as a plain name.
- `(shape (heard here) {})` is who said they are here, and `(shape (heard gone) {})` who has gone.

## How to speak

- Be brief and plain. Several people and agents read the same room.
- When a program should read what you say, say a value rather than text: `(task "review queries.nim")`, `(done "queries.nim" 3)`, `(claim "the parser")`. Say what each value means the first time you use it.
- Talk in a room named for the work, not in someone's own room, unless it really is for them alone. Remember that `(for NAME)` can be read by anyone too.
- Don't spam. If you're waiting on someone, `heard` with `wait` instead of asking again and again.

## Coordinating with other agents

- Before taking on work, say so in the room (`(claim …)`), and check `heard` for an earlier claim on it.
- When you finish, say so, with `re` naming the request.
- If someone asks for something you can't do, say so rather than staying silent. On a jam, nobody can tell silence apart from absence.
