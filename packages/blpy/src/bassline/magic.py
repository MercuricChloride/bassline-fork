"""``bl magic``: format conversion through values, guessing what it isn't
told.

    bl magic data.json                    # JSON in, CE on stdout
    bl magic data.json out.toml           # convert through values
    cat notes.csv | bl magic              # sniff stdin, CE on stdout
    bl magic - out.csv                    # CE on stdin, CSV file out
    bl magic data.json -t text            # the textual syntax, for people
    bl magic in.csv out.json -l header -l numbers    # levers, in order
    bl magic -l keys-as-symbols           # CE in, CE out: one lever as a filter
    bl magic --readings notes.txt -t text # every plausible reading
    bl magic --formats                    # what this magic reads and writes
    bl magic --levers                     # and which levers it has

The input format is ``-f`` if given, else the input file's extension, else
a guess from the content; the output format is ``-t``, else the output
file's extension, else CE. What it guessed it says on stderr. CE input is
converted as it streams in, so with CE on stdin this is a filter; any
other format is a whole document, read once its input ends.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import threading
from collections.abc import Iterator
from itertools import chain

from . import doors, levers
from .cli import Misuse, Opt, Tool, say
from .codec import iterdecode
from .doors import Door
from .edge import CHUNK, CEWriter, chunks, read_ce
from .errors import BasslineError, NotHeld
from .search import through
from .values import Value, rec

__all__ = ["main", "convert", "lift", "External"]


def _readall(fd: int, head: bytes = b"") -> bytes:
    return head + b"".join(chunks(fd))


def _sniff(fd: int) -> tuple[str, bytes]:
    """Read the start of the input until it shows whether it is a stream of
    CE: ``("ce", head)`` as soon as it can only be CE, else ``("whole",
    everything)`` once the bytes break CE's rules or the input ends."""
    head = bytearray()
    while True:
        b = os.read(fd, CHUNK)
        if not b:
            return "whole", bytes(head)
        head += b
        said = doors.ce.stream_head(bytes(head))
        if said == "ce":
            return "ce", bytes(head)
        if said == "not":
            return "whole", _readall(fd, bytes(head))


def _read_whole(door: Door, data: bytes, reading: str | None, name: str) -> list[Value]:
    """The document by the reading asked for, or by the door's readings in
    its order of preference, taking the first that holds."""
    names = [reading] if reading else list(door.readings)
    refused: BasslineError | None = None
    for r in names:
        try:
            values = list(door.read(data, r))
        except BasslineError as e:
            refused = refused or e
            continue
        if refused is not None:
            say(f"{name}: the {names[0]} reading refused it ({refused}); read as {r}")
        return values
    raise refused


class _Out:
    """The output: stdout unbuffered, or a file opened when the first value
    is written, so a conversion that writes nothing leaves no file."""

    def __init__(self, path: str):
        self.path = path
        self.f = None

    def write(self, b) -> int:
        if self.f is None:
            if self.path == "-":
                self.f = open(sys.stdout.fileno(), "wb", buffering=0, closefd=False)
            else:
                try:
                    self.f = open(self.path, "wb")
                except OSError as e:
                    raise _WriteRefused(f"can't write {self.path}: {e.strerror}") from None
        return self.f.write(b)

    def flush(self) -> None:
        if self.f is not None:
            self.f.flush()

    def close(self) -> None:
        if self.f is not None:
            self.f.close()


class _WriteRefused(NotHeld):
    pass


class _Writing:
    """The output's send, saying how it writes before the first value, and
    naming the output when the format can't hold a value."""

    def __init__(self, send, where: str, fmt: str, note: str):
        self.send, self.where, self.fmt, self.note = send, where, fmt, note

    def __call__(self, v: Value) -> bool:
        if self.note:
            say(self.note)
            self.note = ""
        try:
            return self.send(v)
        except _WriteRefused:
            raise
        except NotHeld as e:
            raise _WriteRefused(f"{self.where}: can't write that as {self.fmt}: {e}") from None


def _door_named(name: str, *, writing: bool) -> Door:
    try:
        d = doors.named(name)
    except LookupError:
        raise Misuse(f"no format {name} (--formats lists them)") from None
    if writing and name not in d.writers and name != d.name:
        raise Misuse(f"{name} is a reading; write as {d.name}")
    if not d.available:
        raise NotHeld(f"the {d.name} format needs {d.needs}, which isn't installed")
    return d


class External:
    """A lever this magic doesn't have, offered as ``bl-search-NAME`` on PATH
    (by any implementation), run as a stage: the values go to its stdin as
    CE from a thread of their own, and the values its stdout carries go on.
    Its chatter goes to stderr as it is."""

    def __init__(self, name: str, path: str, arg: str | None):
        self.name, self.argv = name, [path] + ([arg] if arg is not None else [])

    def stage(self, values: Iterator[Value]) -> Iterator[Value]:
        proc = subprocess.Popen(self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                bufsize=0)
        failed: list[BaseException] = []

        def feed() -> None:
            send = CEWriter(proc.stdin)
            try:
                for v in values:
                    if send(v) is False:
                        break
            except BaseException as e:   # upstream refused or ended partway: said after
                failed.append(e)
            finally:
                try:
                    proc.stdin.close()
                except OSError:
                    pass

        feeder = threading.Thread(target=feed, daemon=True, name=f"lever {self.name}")
        feeder.start()
        try:
            yield from read_ce(proc.stdout)
        except GeneratorExit:
            proc.stdout.close()     # downstream has gone; so may this stage
            raise
        proc.stdout.close()
        feeder.join()
        status = proc.wait()
        if failed:
            raise failed[0]
        if status:
            raise NotHeld(f"the lever {self.name} (bl-search-{self.name}) exited with status {status}")


def _lever(spec: str):
    """A lever named on the command line: one of this magic's own, else
    ``bl-search-NAME`` from PATH, as `bl search NAME` would run it."""
    name, eq, arg = spec.partition("=")
    if levers.named(name) is None:
        path = shutil.which(f"bl-search-{name}")
        if path is not None:
            return External(name, path, arg if eq else None)
        raise Misuse(f"no lever {name}, and no bl-search-{name} on PATH (--levers lists them)")
    try:
        return levers.lever(spec)
    except ValueError as e:
        raise Misuse(str(e)) from None


def lift(values: Iterator[Value], searches: list) -> Iterator[Value]:
    """Each value through the levers, in order. A run of this magic's own
    levers is asked about each value in turn, its readings of one value
    alternated fairly and drained before the next value is pulled, so a
    live input isn't held waiting for its next arrival; an
    :class:`External` lever is a stage over the whole stream."""
    run: list = []
    for s in searches:
        if isinstance(s, External):
            if run:
                values = chain.from_iterable(map(through(*run), values))
                run = []
            values = s.stage(values)
        else:
            run.append(s)
    if run:
        values = chain.from_iterable(map(through(*run), values))
    return values


def convert(values: Iterator[Value], searches: list, send) -> None:
    """Each value through the levers (see :func:`lift`), its answers handed
    to ``send`` until it answers ``False`` (whoever reads the output has
    gone; a send that answers nothing at all is taken to carry on)."""
    for v in lift(values, searches):
        if send(v) is False:
            return


def _run(tool: Tool, opts: dict, args: list[str]) -> int:
    if opts.get("formats"):
        return _list_formats()
    if opts.get("levers"):
        return _list_levers()
    if len(args) > 2:
        raise Misuse(f"takes an input and an output at most, got {len(args)} arguments")
    inp = args[0] if args else "-"
    outp = args[1] if len(args) > 1 else "-"
    name = "stdin" if inp == "-" else inp

    searches = [_lever(spec) for spec in opts["lever"]]

    src = reading = None
    if opts.get("from"):
        src = _door_named(opts["from"], writing=False)
        # a format's name means its readings, in its order; a reading's name, that one
        reading = opts["from"] if opts["from"] in src.readings[1:] else None

    write_note = ""
    if opts.get("to"):
        dst = _door_named(opts["to"], writing=True)
        dst_name = opts["to"] if opts["to"] in dst.writers else dst.writers[0]
    elif outp != "-" and doors.by_extension(outp) is not None:
        dst = doors.by_extension(outp)
        if not dst.available:
            raise NotHeld(f"the {dst.name} format needs {dst.needs}, which isn't installed")
        dst_name = dst.writer_for(outp)
        write_note = f"writing {outp} as {dst_name} (from its extension)"
    else:
        dst, dst_name = doors.ce.door, "ce"
        if outp != "-":
            write_note = f"writing {outp} as ce (no format known for its extension)"

    if inp != "-" and outp != "-" and os.path.exists(outp):
        try:
            if os.path.samefile(inp, outp):
                raise Misuse("the input and the output are the same file")
        except OSError:
            pass

    by_ext = doors.by_extension(inp) if inp != "-" else None
    if src is None and by_ext is not None and not opts.get("readings"):
        if not by_ext.available:
            raise NotHeld(f"the {by_ext.name} format needs {by_ext.needs}, which isn't installed")
        src = by_ext
        say(f"reading {name} as {src.name} (from its extension)")

    try:
        if os.path.isdir(inp):
            raise IsADirectoryError(21, "Is a directory")
        fd = 0 if inp == "-" else os.open(inp, os.O_RDONLY)
    except OSError as e:
        say(f"can't read {inp}: {e.strerror}")
        return 1
    tool.where = name

    out = _Out(outp)
    send = _Writing(dst.writer(out, dst_name), "stdout" if outp == "-" else outp,
                    dst_name, write_note)
    try:
        if opts.get("readings"):
            data = _readall(fd)
            if not data:
                return 0
            among = [src] if src is not None else doors.ALL
            # -f is taken at its word: its readings count however unsure the door is
            found = doors.readings(data, among, prefer=by_ext,
                                   at_least=0 if src is not None else doors.PLAUSIBLE)
            if reading is not None:
                found = (r for r in found if r[1].name == reading)
            values = (rec(r.head, r[1], v) for r in found for v in lift(iter((r[2],)), searches))
            wrote = False
            for v in values:
                wrote = True
                if send(v) is False:
                    break
            if not wrote:
                if src is not None:
                    _read_whole(src, data, reading, name)   # says why the reading refused
                say(f"{name}: no plausible reading")
                return 1
            return 0

        if src is doors.ce.door:
            values = iterdecode(chunks(fd))
        elif src is not None:
            data = _readall(fd)
            if not data:
                return 0
            values = iter(_read_whole(src, data, reading, name))
        else:
            said, data = _sniff(fd)
            if not data:
                return 0
            if said == "ce":
                say(f"reading {name} as ce (guessed from content)")
                values = iterdecode(chain((data,), chunks(fd)))
            else:
                ranked = [(s, d) for s, d in doors.guess(data) if s >= doors.PLAUSIBLE]
                if not ranked:
                    hint = ""
                    if not doors.yaml.door.available:
                        hint = " (yaml would need PyYAML, which isn't installed)"
                    say(f"can't tell what format {name} is; say it with -f{hint}")
                    return 1
                src = ranked[0][1]
                say(f"reading {name} as {src.name} (guessed from content)")
                values = iter(_read_whole(src, data, None, name))
        convert(values, searches, send)
        return 0
    except _WriteRefused as e:
        tool.where = ""
        say(str(e))
        return 1
    finally:
        out.close()
        if fd != 0:
            os.close(fd)


def _list_formats() -> int:
    rows = []
    for d in doors.KNOWN:
        ways = "/".join(w for w, has in (("read", d.readings), ("write", d.writers)) if has)
        notes = d.summary
        extra = [r for r in d.readings[1:]] + [w for w in d.writers if w != d.name]
        if extra:
            notes += f"; also {', '.join(extra)}"
        if not d.available:
            notes += f" [needs {d.needs}, not installed]"
        rows.append((d.name, ways, " ".join(d.extensions), notes))
    widths = [max(len(r[i]) for r in rows) for i in range(3)]
    for r in rows:
        sys.stdout.write("  ".join(c.ljust(w) for c, w in zip(r, widths)) + "  " + r[3] + "\n")
    sys.stdout.flush()
    return 0


def _on_path() -> list[tuple[str, str]]:
    """Each ``bl-search-NAME`` on PATH that isn't one of this magic's own
    levers, first on PATH winning."""
    found: dict[str, str] = {}
    for d in os.environ.get("PATH", "").split(os.pathsep):
        try:
            entries = sorted(os.listdir(d or "."))
        except OSError:
            continue
        for f in entries:
            name = f[len("bl-search-"):]
            if (f.startswith("bl-search-") and name and name not in found
                    and levers.named(name) is None and os.access(os.path.join(d, f), os.X_OK)):
                found[name] = os.path.join(d, f)
    return sorted(found.items())


def _list_levers() -> int:
    rows = [(lv.spelling, lv.summary) for lv in levers.LEVERS]
    rows += [(f"{name}[=ARG]", f"bl-search-{name} on PATH: {path}") for name, path in _on_path()]
    width = max(len(r[0]) for r in rows)
    for spelling, summary in rows:
        sys.stdout.write(f"{spelling.ljust(width)}  {summary}\n")
    sys.stdout.flush()
    return 0


TOOL = Tool(
    name="bl magic",
    synopsis="[INPUT [OUTPUT]] [-f FMT] [-t FMT] [-l LEVER[=ARG]]... [--readings]",
    summary="convert between formats through values, guessing what it isn't told",
    run=_run,
    opts=(
        Opt("from", "f", "FMT", "read the input as FMT"),
        Opt("to", "t", "FMT", "write the output as FMT"),
        Opt("lever", "l", "LEVER[=ARG]", "a search over the values, between reading "
            "and writing", repeat=True),
        Opt("readings", None, None, "write every plausible reading as (reading FMT "
            "value) instead of choosing"),
        Opt("formats", None, None, "list the formats this magic reads and writes"),
        Opt("levers", None, None, "list its levers"),
    ),
    about="""
The input format is -f if given, else INPUT's extension, else a guess from
the content; the output format is -t, else OUTPUT's extension, else CE.
No INPUT, or -, is stdin; no OUTPUT, or -, is stdout. Whatever it guessed,
it says on stderr. CE input streams: each value is converted as soon as it
arrives, so with CE on stdin `bl magic -l keys-as-symbols` is a filter.
Levers run in the order given; a lever this magic doesn't have runs as
bl-search-NAME from PATH, from any implementation. Empty input writes
nothing.
""")


def main(argv: list[str] | None = None) -> int:
    return TOOL.main(argv)


if __name__ == "__main__":
    sys.exit(main())
