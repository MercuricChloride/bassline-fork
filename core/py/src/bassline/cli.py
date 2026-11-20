"""What the ``bl`` tools here share: options, help, chatter, and the pipe
rule's exits.

- ``-h``/``--help`` prints usage on stdout and exits 0; an unknown option or
  a wrong argument count prints one line of reason and the usage on stderr
  and exits 2. Long options take ``--name value``, ``--name=value`` or
  ``--name:value``.
- Chatter goes to stderr, one line per event, starting ``-- ``.
- A closed downstream pipe ends a tool quietly with exit 0. Input that ends
  partway through a value, input that breaks a rule (named by its corpus
  reason), and anything a reading refuses are said on stderr with exit 1.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field

from .codec import decode
from .errors import DecodeError, Incomplete, Refused
from .text import read
from .values import Value

__all__ = ["Opt", "Tool", "Misuse", "say", "value_arg"]


def say(message: str) -> None:
    """One line of chatter on stderr, starting ``-- ``."""
    line = " ".join(str(message).splitlines())
    try:
        sys.stderr.write(f"-- {line}\n")
        sys.stderr.flush()
    except (BrokenPipeError, ValueError):
        pass


class Misuse(Exception):
    """A wrong option or argument: one line of reason, then the usage, exit 2."""


@dataclass(frozen=True)
class Opt:
    long: str
    short: str | None = None
    arg: str | None = None       # the value's name in the usage; None for a flag
    help: str = ""
    repeat: bool = False


@dataclass
class Tool:
    """A command-line tool: its synopsis, options, and what it runs.

    ``run(tool, opts, args)`` gets the parsed options (a dict from long
    name to a value, a list for repeatable options, ``True`` for flags) and
    the positional arguments, and returns an exit status (``None`` is 0).
    """

    name: str
    synopsis: str
    summary: str
    run: Callable[..., int | None]
    opts: Sequence[Opt] = ()
    about: str = ""
    where: str = field(default="", repr=False)   # what is being read, for chatter

    def usage(self) -> str:
        lines = [self.summary, "", f"usage: {self.name} {self.synopsis}".rstrip()]
        if self.opts:
            lines.append("")
            rows = []
            for o in self.opts:
                spell = f"-{o.short}, --{o.long}" if o.short else f"    --{o.long}"
                if o.arg:
                    spell += f" {o.arg}"
                rows.append((spell, o.help + (" (repeatable)" if o.repeat else "")))
            rows.append(("-h, --help", "this help"))
            width = max(len(s) for s, _ in rows)
            lines.extend(f"  {s.ljust(width)}  {h}".rstrip() for s, h in rows)
        if self.about:
            lines.extend(("", self.about.strip()))
        return "\n".join(lines) + "\n"

    def parse(self, argv: Sequence[str]) -> tuple[dict, list[str]]:
        longs = {o.long: o for o in self.opts}
        shorts = {o.short: o for o in self.opts if o.short}
        opts: dict = {o.long: [] for o in self.opts if o.repeat}
        args: list[str] = []
        it = iter(argv)
        for a in it:
            if a == "--":
                args.extend(it)
                break
            if a in ("-h", "--help"):
                raise _Help
            if a.startswith("--"):
                name, sep, val = a[2:], "", None
                for i, c in enumerate(name):
                    if c in "=:":
                        name, sep, val = name[:i], c, name[i + 1:]
                        break
                o = longs.get(name)
                if o is None:
                    raise Misuse(f"unknown option --{name}")
            elif a.startswith("-") and a != "-":
                o = shorts.get(a[1])
                if o is None:
                    raise Misuse(f"unknown option {a[:2]}")
                sep = ""
                val = a[2:] or None
                if val is not None and o.arg is None:
                    raise Misuse(f"-{o.short} takes no value: {a}")
            else:
                args.append(a)
                continue
            if o.arg is None:
                if sep:
                    raise Misuse(f"--{o.long} takes no value")
                opts[o.long] = True
                continue
            if val is None:
                val = next(it, None)
                if val is None:
                    raise Misuse(f"--{o.long} needs {o.arg}")
            if o.repeat:
                opts[o.long].append(val)
            else:
                opts[o.long] = val
        return opts, args

    def main(self, argv: Sequence[str] | None = None) -> int:
        argv = sys.argv[1:] if argv is None else list(argv)
        try:
            opts, args = self.parse(argv)
        except _Help:
            return _guarded(lambda: _out(self.usage()))
        except Misuse as e:
            sys.stderr.write(f"{self.name}: {e}\n{self.usage()}")
            return 2
        try:
            return self.run(self, opts, args) or 0
        except Misuse as e:
            sys.stderr.write(f"{self.name}: {e}\n{self.usage()}")
            return 2
        except BrokenPipeError:
            _quiet_stdout()
            return 0
        except Incomplete as e:
            if e.line is None:
                say(f"{self._at()}input ended partway through a value (at byte {e.offset})")
            else:
                say(f"{self._at()}text ended partway through a value "
                    f"(line {e.line}, column {e.column})")
            return 1
        except DecodeError as e:
            say(f"{self._at()}malformed input: {e.reason} at byte {e.offset}")
            return 1
        except Refused as e:
            say(f"{self._at()}{e}")
            return 1
        except KeyboardInterrupt:
            return 130

    def _at(self) -> str:
        return f"{self.where}: " if self.where else ""


class _Help(Exception):
    pass


def _out(text: str) -> None:
    sys.stdout.write(text)
    sys.stdout.flush()


def _guarded(fn: Callable[[], None]) -> int:
    try:
        fn()
    except BrokenPipeError:
        _quiet_stdout()
    return 0


def _quiet_stdout() -> None:
    """Downstream has gone: point stdout at the null device, so nothing left
    in a buffer complains at exit."""
    try:
        fd = os.open(os.devnull, os.O_WRONLY)
        os.dup2(fd, sys.stdout.fileno())
        os.close(fd)
    except (OSError, ValueError):
        pass


def value_arg(arg: str, *, files: bool = True) -> Value:
    """An argument that stands for a value, read by recognition: the file it
    names if there is one (with ``files``), otherwise the argument itself.
    A file is CE if it decodes to one value, else the textual syntax. An
    argument typed inline is the textual syntax first, and CE only if the
    text refuses, as blcli reads it: CE rarely survives being a shell
    argument, while plain spellings often decode as CE by accident (``10``
    is the CE of the text ``"0"``)."""
    if files and os.path.isfile(arg):
        with open(arg, "rb") as f:
            raw = f.read()
        try:
            return decode(raw)
        except (Refused, Incomplete):
            return _text_arg(arg, raw)
    try:
        return read(arg)
    except (Refused, Incomplete) as e:
        try:
            return decode(os.fsencode(arg))
        except (Refused, Incomplete):
            raise Misuse(f"{arg!r} is neither one value in the textual syntax nor CE ({e})") from None


def _text_arg(arg: str, raw: bytes) -> Value:
    try:
        return read(raw.decode("utf-8"))
    except UnicodeDecodeError:
        raise Misuse(f"{arg} is neither CE nor UTF-8 text") from None
    except (Refused, Incomplete) as e:
        raise Misuse(f"{arg} is neither CE nor one value in the textual syntax ({e})") from None
