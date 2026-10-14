"""What every format door has: a first pass in, a writer out, and a guess."""

from __future__ import annotations

import io
from collections.abc import Callable, Iterator
from typing import Any

from ..edge import write_all
from ..errors import NotHeld
from ..values import Value, _read

__all__ = ["Door", "TextWriter", "text_of", "utf8_or_none", "spelled_keys"]


def spelled_keys(d: Value, spell: Callable[[Value], Any], fmt: str) -> list[tuple[Any, Value]]:
    """A dict's entries with each key as a format spells it, refusing two
    keys that would be spelled alike (``{1: a "1": b}`` as JSON), since the
    format can't hold both."""
    seen: dict = {}
    out = []
    for k, v in d.items():
        name = spell(k)
        if name in seen:
            raise NotHeld(f"the keys {seen[name]} and {k} would both be {name!r} in {fmt}, "
                          "which can't hold both")
        seen[name] = k
        out.append((name, v))
    return out


def text_of(data: bytes | str, what: str) -> str:
    """A document's text: ``str`` as it is, bytes decoded as UTF-8 (a
    leading byte-order mark is the encoding's, not the document's, and is
    dropped). Bytes that aren't UTF-8 are refused."""
    if isinstance(data, str):
        return data[1:] if data.startswith("\ufeff") else data
    data = bytes(data)
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise NotHeld(f"{what} is read as UTF-8, and byte {e.start} isn't") from None


def utf8_or_none(data: bytes | str) -> str | None:
    """The text of ``data`` if it is UTF-8, else ``None`` (for guessing)."""
    try:
        return text_of(data, "")
    except NotHeld:
        return None


class TextWriter:
    """A send that writes each value as text a format holds, rendered by
    ``render(value) -> str``, encodes it as UTF-8, writes it whole and
    flushes. It answers ``True`` once written and ``False`` once whoever
    reads the output has gone. What the format can't hold raises
    :class:`~bassline.NotHeld` from ``render``."""

    __slots__ = ("_out", "_render", "gone")

    def __init__(self, out: Any, render: Callable[[Value], str]):
        self._out = out
        self._render = render
        self.gone = False

    def __call__(self, value: Any) -> bool:
        if self.gone:
            return False
        try:
            text = self._render(_read(value))
        except RecursionError:
            raise NotHeld("nested deeper than this writer can follow") from None
        try:
            write_all(self._out, text.encode("utf-8"))
        except BrokenPipeError:
            self.gone = True
            return False
        return True


class Door:
    """A format door.

    - :meth:`read` is a search from a document to the values it holds, in
      document order. Each door's first pass keeps everything the document
      says, in arrangements that hold it exactly, and refuses
      (:class:`~bassline.NotHeld`) only what values can't hold. A door may
      have several readings, named in ``readings``, preferred first.
    - :meth:`sure` says, 0 to 100, how sure the door is that some bytes are
      its format, for guessing.
    - :meth:`writer` is a send that writes each value it is handed in the
      format. Going out is lossy: a writer drops what the format can't say
      (marks, the difference between a symbol and text) and refuses only
      what it can't write at all.
    """

    name: str = ""
    summary: str = ""
    extensions: tuple[str, ...] = ()
    readings: tuple[str, ...] = ()
    writers: tuple[str, ...] = ()
    #: Writers chosen by an output file's extension, where not the first.
    extension_writers: dict[str, str] = {}
    #: Empty when the door works here; otherwise what it is missing.
    needs: str = ""

    @property
    def available(self) -> bool:
        return not self.needs

    def sure(self, data: bytes | str) -> int:
        """How sure this door is, 0 to 100, that ``data`` is its format."""
        return 0

    def read(self, data: bytes | str, reading: str | None = None) -> Iterator[Value]:
        """The values a document holds, by the reading named (the door's
        first, by default)."""
        self._check()
        if reading is None:
            reading = self.readings[0]
        elif reading not in self.readings:
            raise ValueError(f"the {self.name} door has no reading {reading!r}; "
                             f"it has {', '.join(self.readings)}")
        return self._read(data, reading)

    def loads(self, data: bytes | str, reading: str | None = None) -> Value:
        """The one value a document holds."""
        values = list(self.read(data, reading))
        if len(values) != 1:
            raise NotHeld(f"expected one value in the {self.name} document, "
                          f"found {len(values)}")
        return values[0]

    def writer(self, out: Any, name: str | None = None):
        """A send writing each value to ``out`` (a binary file or a file
        descriptor), by the writer named (the door's first, by default)."""
        self._check()
        if name is None:
            name = self.writers[0]
        elif name not in self.writers:
            raise ValueError(f"the {self.name} door has no writer {name!r}; "
                             f"it has {', '.join(self.writers) or 'none'}")
        return self._writer(out, name)

    def writer_for(self, path: str) -> str:
        """The writer an output file's name asks for."""
        base = path.lower()
        for ext, name in self.extension_writers.items():
            if base.endswith(ext):
                return name
        return self.writers[0]

    def dumps(self, value: Any, name: str | None = None) -> str | bytes:
        """One value, written: text for a text format."""
        buf = io.BytesIO()
        self.writer(buf, name)(value)
        return buf.getvalue().decode("utf-8")

    def _check(self) -> None:
        if self.needs:
            raise NotHeld(f"the {self.name} door needs {self.needs}, which isn't installed")

    def _read(self, data, reading: str) -> Iterator[Value]:  # pragma: no cover
        raise NotImplementedError

    def _writer(self, out, name: str):  # pragma: no cover
        raise NotImplementedError

    def __repr__(self) -> str:
        return f"<door {self.name}>"
