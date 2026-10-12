# The bl toolkit

Conventions every `bl` tool follows, in any implementation, so that tools from different implementations compose in one pipeline.

## Contents

- Dispatch
- The pipe rule
- Filters are searches
- Places
- Value arguments
- Options, help and exit codes
- bl search
- bl jam
- bl magic

## Dispatch

`bl NAME args…` runs a builtin if `bl` has one, and otherwise executes `bl-NAME` with the same arguments, stdio and exit status, looking beside `bl` first (so tools built together stay together, however `bl` was reached) and then on PATH. A tool in any language joins the toolkit by being an executable named `bl-NAME`. `bl which NAME` says what would run; `bl commands` lists builtins and every `bl-*` on PATH but the searches, which `bl search` lists, each with a line of help and no paths. One table generates dispatch, help and `which`, so they can't drift.

## The pipe rule

- stdin and stdout carry bare concatenations of CE and nothing else, unless a tool's job is reading or writing another format, in which case a file name or a format option says so.
- Read with unbuffered reads (raw `read(2)`, or the host's equivalent) and act on each value as soon as it completes; buffered reads stall a live pipeline until EOF. Flush after every value written.
- Chatter goes to stderr, one line per event, starting `-- `. Nothing but CE ever goes to stdout.
- When downstream has gone (a closed pipe), exit 0 quietly.
- Empty input is silence: write nothing, exit 0.
- Input that ends partway through a value: say so on stderr, exit 1.
- Malformed input: name the corpus reason on stderr and exit 1. A listener facing strangers drops that connection instead and carries on.

## Filters are searches

A filter asks a search about each incoming value and writes whatever the stream answers: nothing, one value, or many. One function per tool, lifted over the input; filters compose by piping.

## Places

Where bytes go to or come from, for edge tools such as `send`, `serve` and `reach`:

- `tcp://host:port`, `host:port`, `:port` or a bare port: TCP, with host defaulting to `127.0.0.1`. Places are TCP only; a path is refused (exit 2).
- `ssh://host[/PLACE]`: runs `bl reach PLACE` on the far side, its default place when PLACE is left out.

A place is for people and the edge. It never goes into a value. `bl send` and `bl serve` share a default place, `127.0.0.1:8455`, so they meet with no arguments.

## Value arguments

An argument that stands for a value is read by recognition. If a file by that name exists, its contents are read as CE if they decode to one value, otherwise as the textual syntax. Otherwise the argument itself is read as the textual syntax first and as CE only if text refuses, since printable text such as `10` also happens to decode as CE.

## Options, help and exit codes

- `-h` or `--help` prints usage on stdout and exits 0. So does `bl` alone: its usage lists every command with a line of help each.
- An unknown option or a wrong argument count prints one line of reason and the usage on stderr, and exits 2.
- Otherwise 0 means success and 1 failure, unless a tool documents more (a filter may use 1 for "nothing matched").
- Long options take `--name value`, `--name=value` or `--name:value`.

## bl search

Search is the toolkit's centre. Every filter is already a search; `bl search` is the explicit form, and a pipeline is how searches feed each other.

```
bl search                                        # which searches exist here
bl search under '(person)' < known.blb           # every known value under a prefix
bl search match '(shape (person x) {x})' < known.blb   # every filling of a shape
bl search walk < doc.blb                         # every subvalue of each value
bl search under '(person)' -n 10 < known.blb     # take ten, then stop
bl serve | bl search under '(person)' | bl cat   # keeps answering as values arrive
```

- The first argument names the search; the rest are its query, read as value arguments. Values on stdin are what that run of the search can reach. Some searches answer from all of them (`under`, `match`), some ask about each in turn (`walk`); each search says which in its help.
- The answers are the stream, written as CE on stdout. Downstream reading the pipe is pulling it: a search runs only as far as its output is read, `-n N` takes N answers and stops, and a closed pipe (`| head`) stops it quietly. Running it again is asking again.
- A search reading a stdin that never closes (`bl serve | bl search …`) keeps answering as what it can reach grows.
- `bl search NAME` runs a builtin search or `bl-search-NAME` from PATH, so searches from any implementation join the same way tools do. `bl search` alone lists them, with a line of help each.
- Levers in `bl magic` are searches; an implementation that has a lever also offers it as `bl search NAME`.

## bl jam

A place where people, agents and programs talk, built from the convention search spaces keep. Over a connection, `(Q A)` puts A as an answer to the question Q and `(Q)` asks Q. The jam tells each line that asks the record `(Q R A)` for every answer to Q, what it has and then each as it comes, R the order it heard them in.

```
bl jam serve                         # a jam on 127.0.0.1:8456, kept in ~/.bl/jams/jam.blb
bl jam serve --as tea --new          # begin another jam, kept as ~/.bl/jams/tea.blb
bl jam serve --as tea                # serve it again, whatever it held
bl jam list | bl cat                 # every jam kept: (jam NAME {kept records rooms who began last served})
bl jam serve --clave                 # taking only what bl clave signed
bl jam                               # a terminal on it: rooms, /msg, /re, /who
bl jam mcp                           # an agent on it, over MCP on stdio
echo '(general !{(by bot) (said "hi")})' | bl read | bl reach --source :8456
echo '(general)' | bl read | bl reach :8456 | bl cat    # every answer, as it comes
bl read < said.bl | bl clave sign | bl reach --source :8456   # signed
bl jam serve --key ~/.bl/jam-key.blb  # signing its own order: (stamps jam)
bl ws                                # a door for pages: ws://127.0.0.1:8457 to the jam
bl ws --to :8455 --origin 'http://localhost:*'   # to bl serve or the Mac app instead
```

- `bl ws` is the door for a browser, which can't dial TCP: each WebSocket gets its own TCP connection to the place behind (`--to`), one CE value a binary frame going out, and each binary message coming in carried on as the values it holds, or not at all if it isn't whole CE. It listens on loopback only and refuses an opening whose Origin fits no `--origin` pattern (default `http://localhost:*` and `http://127.0.0.1:*`); when either side ends it ends the other.

- The jam reads neither questions nor answers. What people share on top is a convention:
  - a room is a question;
  - a message is an object answering `by`, `said` and `at`, and maybe `re` (a digest) and `for`;
  - `(for NAME)` is someone's own room;
  - `(here …)` and `(gone …)` say who is listening;
  - `(rooms ROOM)` lists a room.
- Any program is a participant through `bl reach`, so an evaluator is a pipeline: ask a room, read what is said, put what it makes of it.
- What it keeps is a bare concatenation of the records it was told, so `bl cat ~/.bl/jams/NAME.blb` reads it. Jams are kept by name, and one is served at a time on its log (it holds it locked); a jam answers `(jam)` with which jam it is, so a client dialling its place again hangs up on another jam served there since and waits for its own.

## bl magic

Format conversion with guessing, in the manner of ffmpeg and ImageMagick.

```
bl magic data.json                    # JSON in, CE on stdout
bl magic data.json out.toml           # convert through values
cat notes.csv | bl magic              # sniff stdin, CE on stdout
bl magic - out.csv                    # CE on stdin, CSV file out
bl magic data.json -t text            # the textual syntax, for people
bl magic in.csv out.json -l header -l numbers    # levers, in order
bl magic -l keys-as-symbols           # CE in, CE out: one lever as a filter
bl magic --formats                    # what this magic can read and write
bl magic --levers                     # and which levers it has
```

- The input format is `-f FMT` if given, else the file's extension, else a guess from the content. The output format is `-t FMT` if given, else the output file's extension, else CE.
- With no input argument, or `-`, input is stdin. With no output argument, output is stdout.
- Whatever it guessed, it says on stderr: `-- reading data.txt as csv (guessed from content)`.
- Levers (`-l NAME` or `-l NAME=ARG`, repeatable) are searches over the values, applied in order between reading and writing.
- `--readings`: when the input could be read more than one way, write each plausible reading as `(reading FMT value)` instead of choosing.
- The first pass keeps everything the document says and refuses only what values cannot hold (see `formats.md`); going out is lossy.

Any implementation can provide `bl-magic`; whichever is first on PATH runs.
