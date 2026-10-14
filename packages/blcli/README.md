# blcli

The `bl` command-line toolkit for bassline, in Nim, built on [blnim](../blnim): small tools that read and write bare concatenations of CE on stdin and stdout, so they compose by piping. It follows the toolkit conventions in the bassline-zoo skill's `cli.md`, which any implementation can follow too: a tool in any language joins by being an executable named `bl-NAME` on PATH.

```sh
bl read people.bl | bl search under '(person)' | bl cat
bl serve | bl search under '(order)' | bl hash | bl cat      # keeps answering as values arrive
bl cat corpus.blb | bl read | cmp - corpus.blb               # text and back, byte for byte
bl clave sign < notes.blb | bl send                          # to 127.0.0.1:8455, where bl serve is found here
```

- [Building](#building)
- [The tools](#the-tools)
- [Conventions](#conventions)
- [Design notes](#design-notes)
- [Testing](#testing)
- [Limitations](#limitations)

## Building

Nim 2.2 and atlas. blcli is built from blnim beside it, `../blnim`, and the dependencies `atlas install` puts in `../blnim/deps`. `nim.cfg` names those paths and is checked in. blcli changes nothing in blnim.

```sh
(cd ../blnim && atlas install)   # once: blnim's dependencies
nim build                        # bin/bl, bin/bl-clave and bin/bl-jam, -d:release
nim test                         # build, then run the tests against bin/
export PATH="$PWD/bin:$PATH"     # so you find bl, and bl finds bl-clave beside it
```

`config.nims` holds the `build` and `test` tasks and the compiler flags.

`bl` alone, or `bl --help`, lists every command; at a terminal it puts a banner above the list, in colour unless `NO_COLOR` is set. `bl` holds the builtins below; `bl-clave` is a separate executable so `bl` carries no signing code. If your shell has an alias or function named `bl`, it runs instead of the one on PATH.

## The tools

| Command | What it does |
| --- | --- |
| `bl cat [FILE…] [--width N]` | CE (stdin, or `.blb` files) to the textual syntax, one value per line; `--width` lays each value out within N columns |
| `bl read [FILE…]` | the textual syntax to CE, each value written the moment nothing still to come can change it |
| `bl send [PLACE]` | values on stdin to a place as they arrive; `-- sent N value(s) to PLACE` on stderr |
| `bl serve [PLACE] [--max-value BYTES]` | a listener: each value's CE goes to stdout as it arrives, untouched; edge events on stderr |
| `bl reach PLACE [--source\|--sink] [-- CMD ARGS…]` | a byte pump between a place and stdin/stdout, or a command; never decodes |
| `bl ws [PLACE] [--to PLACE] [--origin PATTERN]… [--max-value BYTES]` | a door for pages in a browser: each WebSocket carried to its own TCP connection, one CE value a binary frame; loopback only, Origins allowlisted |
| `bl hash [--algo sha256\|blake2b]` | each value to `(digest ALGO 0x…)` over its CE bytes |
| `bl search [NAME [QUERY…] [-n N]]` | ask a search about the values on stdin; its answers go to stdout |
| `bl eval [--with FILE]… [-n N] [-q]` | do each value on stdin (blnim's `bl/lang`: the base vocabulary, numbers over vectors, and the rules in each FILE, found first); every answer to stdout, what nothing does and refusals passed over on stderr |
| `bl name [NAME [PLACE…]] [--forget]` | names for places, kept in the config: a name is then the place it names wherever a place is taken |
| `bl config [Q [A…]] [--add] [--forget]` | your own answers, `(Q A)` records in `~/.bl/config.bl`, where the tools look for what their command line and environment don't say: `at`, `as`, `send`, `serve`, `listen`, `(place NAME)`, and `bl config defaults TOOL… OPTION…` for the options a tool is given by default (`--no-defaults` leaves them out) |
| `bl scan [PORT…]` | `bl jam scan`: the places on this machine's networks that take a connection, and what each jam there says it is |
| `bl which NAME`, `bl commands` | what `bl NAME` would run; every builtin and `bl-*`, searches aside |
| `bl clave keygen [--out PATH] [--force]` | a keypair, written owner-only (default `~/.bl/key.blb`); the public key on stderr |
| `bl clave sign [--key PATH]` | each value to `(signed VALUE (signature eddsa-blake2b 0x… 0x…))` |
| `bl clave verify [--drop]` | passes on, whole, each signed value whose signature holds; anything else is fatal, or with `--drop` dropped and counted |

`bl NAME --help` says more about each.

### Places

`send`, `serve` and `reach` take a place, for people and the edge; it never goes into a value.

- `tcp://host:port`, `host:port`, `:port` or a bare port: TCP, host `127.0.0.1` unless given. An IPv6 host goes in brackets.
- `ssh://host/PLACE`: runs `bl reach PLACE` on the far side, where PLACE is a TCP place as the far side reads it; `ssh://host` alone reaches the far side's `127.0.0.1:8455` (`send` and `reach`; a listener is local).

Places are TCP only: a path (`unix:/path`, or any spelling with a slash outside `tcp://`) is refused as a misuse, exit 2.

A name given with `bl name` is the place it names wherever a place is taken, `JAM_AT` among them. A name is a letter, then letters, digits, `.`, `_` and `-`, so no place is spelled like one. A name can name several places, someone's address on this network and their `.local` name say, and is then the first of them that takes a connection within half a second. `bl jam scan` finds places worth naming.

`bl serve` listens on `0.0.0.0:8455` by default, every interface, and `bl send` speaks to `127.0.0.1:8455`, so they meet with no arguments and others on the network reach the listener at this machine's address. `bl serve 127.0.0.1:8455` keeps it to this machine. `bl jam serve` does the same on port 8456. `bl serve :0` listens on whatever port is free and says which.

### Searches

`bl search under PREFIX` answers every value on stdin that the prefix selects: `(person)` selects `(person alice)` and `(person)` but not `(personal x)` or `!(person m)`. `bl search walk` answers every subvalue of each value, depth first, the value itself first. `-n N` takes N answers and stops; a closed pipe stops a search quietly. Any other name runs `bl-search-NAME`, and `bl search` alone lists both kinds with a line of help each (for one found outside, the first line of its `--help`). Shape matching, `match`, waits for shape search.

A query is a value argument, read by recognition: the file it names if there is one, else the argument. A file is CE if it decodes to one value, else the textual syntax. An argument typed inline is the textual syntax first, and CE only if the text refuses, since plain spellings often decode as CE by accident (`10` is the CE of the text `"0"`).

### Edge chatter

`bl serve` says on stderr what happens at the edge, one line each:

```
-- listening on 0.0.0.0:8455
-- open 127.0.0.1:52144
-- truncated 127.0.0.1:52144
-- close 127.0.0.1:52144
-- malformed 127.0.0.1:52150: invalid tag: 0
```

A connection that sends something malformed is dropped and the listener carries on. Nothing is ever spoken back down a connection.

## Conventions

Each tool keeps the pipe rule from `cli.md`:

- stdin and stdout carry CE and nothing else, except where a tool's job is text (`cat`, `read`, help, listings).
- Reads are raw `read(2)`, so each value is acted on as soon as its last byte arrives; each value is written whole before the next.
- Chatter goes to stderr as lines starting `-- `.
- A closed downstream pipe ends a tool quietly with exit 0.
- Empty input is silence and exit 0.
- Input that ends partway through a value, or isn't CE, is said on stderr with exit 1, after the values before it have gone on.
- `-h`/`--help` prints usage on stdout and exits 0; an unknown option or wrong argument count prints one line of reason and the usage on stderr and exits 2. Long options take `--name value`, `--name=value` or `--name:value`.

## Design notes

### One harness

`src/harness.nim` is everything the tools share, so each tool is a page:

- **Reading.** `eachView` reads a file descriptor with raw `read(2)` into a blnim `Decoder`, drains it whole every turn (breaking out of `checked` partway would leave it re-reading an END), hands each value on while its view is live, and compacts. It reports a cut-off or malformed input once the values before it have gone on. Local input has no value-size cap beyond memory: blnim's 100 MiB default is for strangers on a socket.
- **Writing.** `emit` writes with `write(2)` through partial writes, `EINTR`, and `EAGAIN` on a pipe some other program left non-blocking. SIGPIPE is ignored, so a closed pipe arrives as `EPIPE`, which ends the tool with exit 0. A relay (`serve`, `send`) passes a value's CE through untouched; nothing is re-encoded.
- **Filters are searches.** `lift` takes a search, a proc from a value to a stream (blnim's `Stream[A] = proc(): Option[A]`), asks it about each value on stdin, and writes every answer as it is pulled. `hash`, `search`, `clave sign` and `clave verify` are each one search lifted.
- **Options.** A tool declares its options; the wrapper derives parseopt's no-value sets from the declarations, which guards parseopt's two footguns: an empty argument list makes it read the process's own command line, and a flag missing from the no-value sets swallows the next argument. A lone `-` stays an argument.
- **Dispatch.** One table in `src/bl.nim` drives dispatch, the usage, `which` and `commands`. A name that isn't a builtin is `execv`'d as `bl-NAME`, so stdio, exit status and signals carry through; SIGPIPE goes back to its default first, since an ignored signal survives exec. `bl-NAME` is looked for beside `bl` first, so the tools built with it go together however `bl` was reached (an alias, say), then on PATH; lookup takes only executables, as a shell does.

### reach

`reach` is a byte pump with `select` (macOS's `poll` refuses terminals). The socket doesn't block: bytes the place hasn't taken yet wait, stdin isn't read again until they've gone, and the place is heard all the while, so a place that speaks more than it hears can't wedge both sides on full buffers. With `-- CMD`, the socket goes on CMD's stdin and stdout and reach execs it; a CMD name is run through `bl` itself, so it resolves exactly as the dispatcher does. Over `ssh://` with a command, reach starts ssh and the command on a pair of pipes between them and stays, exiting with the command's status, or 1 if ssh failed.

### clave

- `keygen` writes the key through a fresh owner-only file beside the target, then a `link` (which refuses an existing path) or, with `--force`, a rename, so a key is never left half written or briefly readable.
- `verify` passes on exactly `(signed VALUE (signature eddsa-blake2b 0xSIG 0xPUB))`, both records unmarked with exactly those fields: anything riding along in either would pass as attested. blnim's readings (`Signed.fromValue`) read them exactly, and accept any VALUE, marked too. It doesn't unwrap; whose key signed is for whatever reads the output to judge.

## Testing

```sh
nim test              # build, then every tests/t*.nim, saying at the end which failed
nim test jam ws       # build, then only tests/tjam.nim and tests/tws.nim
```

The tests are split by what they drive: `tbasics` (help, dispatch, cat and read, the pipe rule, hash, search, eval), `tplaces` (send and serve, names, the config, reach), `tclave`, `tjam` (serve, list, scan, the terminal's lines, mcp, share), `tplugin` (the jam plugin's launchers) and `tws`. `tests/cli.nim` is what they share. Within one, std/unittest takes test names, `bin/tjam "bl jam scan*"`. They drive the built binaries through a shell and as live child processes, with fakes (`bl-demo`, `bl-search-demo`, a non-executable `bl-clave`, and an `ssh` that runs its command locally) first on PATH:

- every tool's `--help`, misuse and exit 2, the three long-option spellings;
- dispatch to `bl-NAME` with arguments and exit status intact, `which`, `commands`;
- `bl cat | bl read` reproducing `corpus/corpus.blb` byte for byte, with and without `--width`, and `bl read` emitting a value before its input closes;
- empty input, input cut partway through a value, malformed input, and `| head -c 1` exiting 0 quietly;
- `under`, `walk`, `-n`, queries from files, CE and text, the listing, and `bl-search-NAME`;
- a 110 MiB value through a local filter;
- `send` into `serve` over TCP by every spelling and over `ssh://`, the default place (also as bare `ssh://host`), an unreachable place, every path spelling refused with exit 2, truncated and malformed input, `--max-value`;
- `reach` duplex, `--sink`, `-- CMD`, a place that answers eight times what it hears, and over `ssh://`, including ssh failing under a command;
- `keygen`/`sign`/`verify` with marked values, a tampered byte, riders in either record, `--drop` counting.

## Limitations

- **Malformed input names the decoder's reason, not the corpus's.** blnim's `CodecError` carries prose (`invalid tag: 0`), not the corpus reason (`invalid-tag`).
- **`--max-value` is checked after the decoder.** blnim's listener doesn't take a per-listener cap, so `serve` refuses a value bigger than `--max-value` once the decoder has it, and can't raise the cap past blnim's `MaxValueBytes` (100 MiB).
- **TCP in `send` and `serve` is IPv4.** blnim's dialer and listener make IPv4 sockets; `reach` dials either family.
- **`bl read` holds a frame that closes the text so far** until one more character arrives or the input ends: lines are fine, a bare `(a b)` with no newline waits.
- **Inline value arguments read text first**, where `cli.md` says CE first; the convention needs the same change.
- **The public key from `keygen` is said on stderr only**, as prose; a reading of a key file that answers its public half as a value isn't here.
