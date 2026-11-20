"""The edge: where bytes from elsewhere become values, and values leave.

Edge tools work over byte channels (file descriptors, files, pipes, a
command's stdin and stdout) and hand program logic only two things: values,
and sends. :func:`read_ce` turns a channel into a stream of the values it
carries; :func:`ce_writer` turns one into a send; :func:`pipe` runs a
command, offers a send into its stdin (its ``send``) and feeds what its
stdout carries to a local send. Nothing about the channel goes further: no connection, no
address, no end-of-file as a value.

On the channel itself the values are a bare concatenation of canonical
encodings (a ``.blb``), read with raw ``os.read`` so a live pipe hands over
each value as soon as its last byte arrives, and written whole and flushed
per value.
"""

from __future__ import annotations

import io
import os
import select
import subprocess
import threading
from collections.abc import Callable, Iterator, Sequence
from typing import Any, BinaryIO, Union

from .codec import DEFAULT_MAX_DEPTH, DEFAULT_MAX_VALUE_BYTES, iterdecode
from .errors import Incomplete, Refused
from .values import Value, _read

__all__ = ["Send", "chunks", "read_ce", "ce_writer", "CEWriter", "pipe", "Pipe", "write_all"]

#: A send: a callable over a value that may answer, as a host ``True`` or
#: ``False``, whether it was understood enough to act on (for a send that
#: only carries bytes, whether they were accepted for carriage). It never
#: answers what happened.
Send = Callable[[Any], Union[bool, None]]

Source = Union[int, str, os.PathLike, BinaryIO]

CHUNK = 65536


def _fd_chunks(fd: int, size: int) -> Iterator[bytes]:
    while True:
        b = os.read(fd, size)
        if not b:
            return
        yield b


def chunks(source: Source, size: int = CHUNK) -> Iterator[bytes]:
    """The bytes ``source`` carries, as they arrive, until it ends.

    ``source`` is a file descriptor, a path (opened here and closed at the
    end), or a binary file. A file descriptor, or an unbuffered file, is
    read with ``os.read``: each read hands over whatever has arrived, up to
    ``size`` bytes, rather than waiting to fill a buffer. A buffered file
    (``sys.stdin.buffer``, ``open(path, "rb")``) is read with ``read1``,
    which hands over what it has already buffered and then reads at most
    once, so it is as live and loses nothing it had read ahead.
    """
    if isinstance(source, int):
        return _fd_chunks(source, size)
    if isinstance(source, (str, os.PathLike)):
        return _path_chunks(source, size)
    if isinstance(source, io.RawIOBase):
        try:
            return _fd_chunks(source.fileno(), size)
        except (OSError, ValueError):
            pass
    reader = getattr(source, "read1", None) or source.read
    return iter(lambda: reader(size), b"")


def _path_chunks(path, size: int) -> Iterator[bytes]:
    with open(path, "rb", buffering=0) as f:
        yield from _fd_chunks(f.fileno(), size)


def read_ce(source: Source, *, max_depth: int = DEFAULT_MAX_DEPTH,
            max_value_bytes: int = DEFAULT_MAX_VALUE_BYTES) -> Iterator[Value]:
    """The values a bare concatenation of CE on ``source`` holds, each
    handed over as soon as its last byte has arrived.

    When the bytes end partway through a value the stream raises
    :class:`~bassline.Incomplete` after the values before it; bytes that
    break a rule raise :class:`~bassline.DecodeError`, also after the
    values before them. Empty input is a stream with nothing in it.
    """
    return iterdecode(chunks(source), max_depth=max_depth,
                      max_value_bytes=max_value_bytes)


def write_all(out: Any, data: bytes) -> None:
    """Write all of ``data`` to a file descriptor or a binary file and
    flush it, through partial writes, waiting on a non-blocking one until
    it can take more."""
    view = memoryview(data)
    while view:
        try:
            n = os.write(out, view) if isinstance(out, int) else out.write(view)
        except BlockingIOError as e:
            n = getattr(e, "characters_written", 0) or None
        if n is None:       # non-blocking, and nothing written: wait until it can be
            select.select([], [out if isinstance(out, int) else out.fileno()], [])
            continue
        view = view[n:]
    flush = getattr(out, "flush", None)
    if flush is not None:
        flush()


class CEWriter:
    """A send that writes each value's CE to a channel, whole, and flushes.

    It answers ``True`` once the bytes are handed on, and ``False`` once
    whoever reads the channel has gone (a closed pipe), from then on
    without writing. That is all it can know: carried, or not.
    """

    __slots__ = ("_out", "gone")

    def __init__(self, sink: Any = 1):
        if hasattr(sink, "buffer") and not isinstance(sink, int):
            sink = sink.buffer   # a text stream such as sys.stdout: its bytes
        self._out = sink
        self.gone = False

    def __call__(self, value: Any) -> bool:
        if self.gone:
            return False
        try:
            write_all(self._out, _read(value).ce)
        except BrokenPipeError:
            self.gone = True
            return False
        return True

    def __repr__(self) -> str:
        return f"<CEWriter {'gone' if self.gone else 'open'}>"


def ce_writer(sink: Any = 1) -> CEWriter:
    """A send writing CE to ``sink``: a file descriptor (default 1,
    stdout, unbuffered) or a binary file (written, then flushed)."""
    return CEWriter(sink)


class Pipe:
    """A command running beside this program, spoken to in values.

    The pipe is the edge's handle, for whoever runs the command. What it
    offers program logic is :attr:`send`, a send into the command's stdin
    (each value's CE, written whole and flushed, answering ``True`` once
    handed on and ``False`` once the command has stopped reading), which
    knows nothing of the process. What the command's stdout carries is
    decoded as it arrives and each value handed to ``into``, a local send,
    from a thread of the pipe's own; ``into`` never learns where the values
    came from.

    Closing is a local decision: :meth:`close` stops sending (the command
    sees its input end), waits for what it still has to say to reach
    ``into``, and for it to exit, as long as that takes unless given a
    ``timeout``; leaving a ``with`` block closes it so. If the command's
    output ended partway through a value, or broke a rule, ``failure``
    holds that, the values before it having gone to ``into``. If ``into``
    raised, reading stopped there and :meth:`close` raises it.
    """

    def __init__(self, argv: Sequence[str], into: Send, *, stderr: Any = None,
                 max_depth: int = DEFAULT_MAX_DEPTH,
                 max_value_bytes: int = DEFAULT_MAX_VALUE_BYTES, **popen: Any):
        self._proc = subprocess.Popen(list(argv), stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=stderr,
                                      bufsize=0, **popen)
        writer = CEWriter(self._proc.stdin)
        stdin = self._proc.stdin

        def send(value: Any) -> bool:
            """A send into the command's stdin."""
            return False if stdin.closed else writer(value)

        self.send: Send = send
        self._into = into
        self._limits = (max_depth, max_value_bytes)
        self.failure: BaseException | None = None
        self._raised: BaseException | None = None
        self._reader = threading.Thread(target=self._drain, daemon=True,
                                        name=f"pipe {argv[0]}")
        self._reader.start()

    def _drain(self) -> None:
        out = self._proc.stdout
        try:
            for v in read_ce(out, max_depth=self._limits[0],
                             max_value_bytes=self._limits[1]):
                try:
                    self._into(v)
                except BaseException as e:   # local logic's, not the channel's
                    self._raised = e
                    return
        except (Refused, Incomplete) as e:
            self.failure = e
        finally:
            out.close()

    @property
    def pid(self) -> int:
        return self._proc.pid

    def close(self, timeout: float | None = None) -> int:
        """Stop sending, let the command finish what it has to say, and
        return its exit status."""
        if not self._proc.stdin.closed:
            try:
                self._proc.stdin.close()
            except BrokenPipeError:
                pass
        self._reader.join(timeout)
        status = self._proc.wait(timeout)
        if self._raised is not None:
            raised, self._raised = self._raised, None
            raise raised
        return status

    def __enter__(self) -> Pipe:
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def __repr__(self) -> str:
        return f"<Pipe {self._proc.args!r} pid {self._proc.pid}>"


def pipe(argv: Sequence[str], into: Send, **options: Any) -> Pipe:
    """Run ``argv``, feeding each value its stdout carries to ``into``; the
    pipe's :attr:`~Pipe.send` speaks into its stdin. See :class:`Pipe`.

        heard = Heard()
        with pipe(["bl-search-numbers"], into=heard.add) as numbers:
            to_numbers = numbers.send      # all that program logic needs
            to_numbers(bl('["1.50" "x"]'))
        list(heard)        # [bl('[(dec 150 -2) "x"]')]
    """
    return Pipe(argv, into, **options)
