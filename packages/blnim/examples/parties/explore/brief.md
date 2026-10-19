# Exploring parties: shared brief

## Rules

- Read and write only inside ~/prg/bassline. Never the scratchpad, /tmp or ~/.claude. Redirect output only into your own folder or /dev/null.
- Write only in your own folder, `packages/blnim/examples/parties/explore/NAME/`. Change no other file and make no git commits.
- A party you run for a prototype is served on `[::1]` with `Port(0)`, and your programs attend it there explicitly (`attend(parseIpAddress("::1"), port)`). Never serve at the place of `bassline` or on port 8455, since people and other agents use it. Kill only processes you started.
- Read first: `CLAUDE.md`, `.claude/skills/bassline/SKILL.md`, `packages/blnim/src/bl/parties/` (parties.nim, here.nim, place.nim) and `packages/blnim/examples/parties/` (basics, values, attend, meet).
- Prototypes are Nim built from inside `packages/blnim` (its `nim.cfg` holds the dependency paths). Give your folder a `config.nims` with `switch("path", "$projectDir/../../../../src")`. They must compile and run.
- Write plainly: short sentences, no semicolons, no quippy phrasing. Findings that others will reuse go in bassline values.

## What parties are today

A party is a daemon on one machine, served at the IPv6 place of a value (fd00::/8 plus 120 bits of the blake2b of its CE), the value `bassline` by default, on port 8455. Its whole dialect:

- On connecting, a program is told `(name N S P)`. S is sixteen random bytes the connection goes by and hears. P is what the party goes by.
- The program says `(sub T)`, `(unsub T)` and `(say T V)`. Everyone else who hears T is told `(said N T V S)`. A topic is any value, matched exactly. N is one count for the whole party. A speaker isn't told its own say.
- `(own {T …})`, said first and only first, makes the connection the owner of those topics until it goes. What others say into an owned topic goes to the owner alone, and what the owner says there goes to everyone who hears it. Asking for a topic already owned is refused and the connection let go, and the attendee's backoff hands the topic over when the old owner goes.
- The party owns `status` and says `(alive S)` and `(dead S)` there, by nil. A new hearer of `status` is told who is already here. Anything outside the dialect is said back into the speaker's name as `(invalid X)`.
- A connection whose input ends has gone. One that leaves more than MaxUnsent bytes unread is let go.
- The attendee reconnects with backoff and repeats its owns and subs. `here.nim` gives every program an implicit `party`, makes any value a topic (`t.say v`, `t.sub`, `t.hear`, `t.each`, `abort`) and gives `me` for whatever the program goes by. `bl party TOPIC` joins shell pipes to a topic.

About 600 lines with doc comments. Reviews found that it would replace about 1,500 lines of connection handling in the jam and in conversations.

## What Goose, the author, has said

- The party is the kernel and participants are user space. To add permissions, gating or anything else, swap the party implementation, or leave your kernel alone and run a new party at a different value. The guarantees a program has are the ones its party gives. Programs get much simpler because behaviour moves into parties.
- Parties are always local and never grow past one machine. Bridges reach other machines, but a bridge still runs on your machine.
- A party modulates what others see. In that it takes the shape we gave conversations.
- Owning a topic is interesting: the owner of a topic plays the role the party plays for itself. "It's almost like a party in a party, where a single participant can encapsulate all conversation within that topic."
- The aim: hyper-connected peer-to-peer software, built in a very different way from existing approaches. A local internet where programs dial values and never handle connections.
- 9P and Croquet are inspirations, much less related overall.

## Settled, don't relitigate

Names given by the party, one per connection, nil being the party's own. Exact topics. No request and response. A speaker isn't told its own say. `own` only as the first thing said. Input ending means gone. Transactions are a library apart from conversations. Parties replace conversations' plumbing. Where you find a real problem with one of these, say it with a concrete case, but design within them.

## Your reply

Under 800 words. The idea in a few sentences first, then what you found as bassline values (`(finding …)`, `(law …)`, `(gap {need: … smallest: …})` and the like), then what you built and how to run it, with line counts. Where something is hard or doesn't work, say so plainly and propose the smallest way through.
