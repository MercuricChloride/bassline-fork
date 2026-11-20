"""The edge: reading and writing CE over byte channels, pipes to commands,
and the pipe rule as the command-line tools keep it."""

import io
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import _path  # noqa: F401
import _tools
from bassline import (
    DecodeError,
    Heard,
    Incomplete,
    bl,
    ce_writer,
    chunks,
    encode,
    encode_all,
    pipe,
    read_ce,
)

VALUES = [bl('{"name": "Ada" "n": "1.50"}'), bl("(f go! !{a: 1} 0xff)"), bl("nil")]


def in_thread(fn, timeout=5.0):
    """``fn()`` run on a thread; its result, or ``TimeoutError`` if it is
    still waiting after ``timeout`` seconds."""
    box = []
    t = threading.Thread(target=lambda: box.append(fn()), daemon=True)
    t.start()
    t.join(timeout)
    if not box:
        raise TimeoutError("still waiting")
    return box[0]


class ReadCE(unittest.TestCase):
    def test_a_value_arrives_before_the_writer_closes(self):
        r, w = os.pipe()
        try:
            stream = read_ce(r)
            os.write(w, encode(VALUES[0]))
            self.assertEqual(in_thread(lambda: next(stream)), VALUES[0])
            os.write(w, encode(VALUES[1])[:3])           # half a value, then the end
            os.close(w)
            w = None
            with self.assertRaises(Incomplete):
                next(stream)
        finally:
            os.close(r)
            if w is not None:
                os.close(w)

    def test_sources(self):
        data = encode_all(VALUES)
        self.assertEqual(list(read_ce(io.BytesIO(data))), VALUES)
        with tempfile.NamedTemporaryFile(suffix=".blb", delete=False) as f:
            f.write(data)
        try:
            self.assertEqual(list(read_ce(f.name)), VALUES)
            with open(f.name, "rb") as g:
                self.assertEqual(list(read_ce(g)), VALUES)
                g.seek(0)
                self.assertEqual(list(read_ce(g.fileno())), VALUES)
        finally:
            os.unlink(f.name)

    def test_a_buffered_file_loses_nothing_it_read_ahead(self):
        data = encode_all(bl(f'"{i}"') for i in range(3000))
        with tempfile.NamedTemporaryFile(suffix=".blb", delete=False) as f:
            f.write(data)
        try:
            with open(f.name, "rb") as g:
                g.read(len(encode(bl('"0"'))))          # the file object reads ahead
                self.assertEqual(len(list(read_ce(g))), 2999)
        finally:
            os.unlink(f.name)

    def test_chunks_hand_over_what_has_arrived(self):
        r, w = os.pipe()
        try:
            os.write(w, b"abc")
            self.assertEqual(in_thread(lambda: next(chunks(r))), b"abc")
        finally:
            os.close(r)
            os.close(w)

    def test_empty_and_broken_input(self):
        self.assertEqual(list(read_ce(io.BytesIO(b""))), [])
        stream = read_ce(io.BytesIO(encode(VALUES[2]) + b"\x00"))
        self.assertEqual(next(stream), VALUES[2])      # the values before a fault go on
        with self.assertRaises(DecodeError) as e:
            next(stream)
        self.assertEqual(e.exception.reason, "invalid-tag")


class CEWriterTests(unittest.TestCase):
    def test_writes_each_value_whole(self):
        buf = io.BytesIO()
        send = ce_writer(buf)
        self.assertIs(send(VALUES[0]), True)
        self.assertIs(send([1, "two"]), True)              # a host value, read by default
        self.assertEqual(buf.getvalue(), encode(VALUES[0]) + encode(bl('[1 "two"]')))

    def test_a_non_blocking_channel_is_waited_on(self):
        r, w = os.pipe()
        os.set_blocking(w, False)
        value = bl('"' + "x" * 300000 + '"')        # more than a pipe holds
        got = []
        reader = threading.Thread(target=lambda: got.extend(read_ce(r)))
        reader.start()
        try:
            self.assertIs(ce_writer(w)(value), True)
        finally:
            os.close(w)
        reader.join(10)
        os.close(r)
        self.assertEqual(got, [value])

    def test_answers_false_once_the_reader_has_gone(self):
        r, w = os.pipe()
        os.close(r)
        try:
            send = ce_writer(w)
            self.assertIs(send(VALUES[0]), False)
            self.assertTrue(send.gone)
            self.assertIs(send(VALUES[1]), False)
        finally:
            os.close(w)


class Pipes(unittest.TestCase):
    def test_values_out_and_back_through_a_command(self):
        heard = Heard()
        with pipe(_tools.argv("bl-search-numbers"), into=heard.add) as numbers:
            to_numbers = numbers.send
            self.assertIs(to_numbers(bl('["1.50" "x" "007"]')), True)
            deadline = time.monotonic() + 10
            while not len(heard) and time.monotonic() < deadline:
                time.sleep(0.01)
            # the answer is back while the command is still running
            self.assertEqual(list(heard), [bl('[(dec 150 -2) "x" "007"]')])
            to_numbers(bl('{"a": "-3"}'))
        self.assertEqual(list(heard)[1], bl('{"a": -3}'))

    def test_a_command_that_has_gone(self):
        p = pipe([sys.executable, "-c", "pass"], into=lambda v: True)
        p._proc.wait()
        answers = [p.send(bl("(x)")) for _ in range(3)]
        self.assertEqual(answers[-1], False)
        self.assertEqual(p.close(), 0)
        self.assertIs(p.send(bl("(x)")), False)

    def test_what_into_raises_comes_back_at_close(self):
        def into(v):
            raise KeyError("local logic")
        p = pipe(_tools.argv("bl-search-numbers"), into=into)
        p.send(bl('"1"'))
        with self.assertRaises(KeyError):
            p.close()
        self.assertIsNone(p.failure)

    def test_output_cut_off(self):
        got = []
        p = pipe([sys.executable, "-c",
                  "import sys; sys.stdout.buffer.write(b'\\x10p')"], into=got.append)
        p.close()
        self.assertEqual(got, [bl("nil")])
        self.assertIsInstance(p.failure, Incomplete)


class PipeRule(unittest.TestCase):
    """bl-search-* and bl-magic keep cli.md's pipe rule."""

    def test_answers_before_input_closes(self):
        for tool, args in (("bl-search-keys-as-symbols", ()), ("bl-magic", ("-l", "numbers"))):
            with self.subTest(tool=tool):
                p = subprocess.Popen(_tools.argv(tool, *args), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    p.stdin.write(encode(bl('{"a": "1"}')))
                    p.stdin.flush()
                    want = encode(bl("{a: \"1\"}") if "keys" in tool else bl('{"a": 1}'))
                    self.assertEqual(_tools.read_exactly(p.stdout, len(want)), want)
                    self.assertIsNone(p.poll())                 # still reading its input
                finally:
                    p.stdin.close()
                    p.wait(10)
                    p.stdout.close()
                    p.stderr.close()
                self.assertEqual(p.returncode, 0)

    def test_downstream_gone_exits_zero_quietly(self):
        data = encode_all(bl(f'{{"k": "{i}"}}') for i in range(50000))
        for tool, args in (("bl-search-keys-as-symbols", ()), ("bl-magic", ("-f", "ce", "-t", "text"))):
            with self.subTest(tool=tool):
                p = subprocess.Popen(_tools.argv(tool, *args), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                feeder = threading.Thread(target=self._feed, args=(p.stdin, data), daemon=True)
                feeder.start()
                self.assertTrue(_tools.read_ready(p.stdout, 10))
                p.stdout.close()                                 # like `| head -c 10`
                err = p.stderr.read()
                p.stderr.close()
                p.wait(20)
                feeder.join(5)
                self.assertEqual(p.returncode, 0)
                self.assertEqual(err, b"")

    @staticmethod
    def _feed(f, data):
        try:
            f.write(data)
        except (BrokenPipeError, ValueError):
            pass
        try:
            f.close()
        except BrokenPipeError:
            pass

    def test_input_ending_partway_through_a_value(self):
        data = encode(VALUES[0]) + encode(VALUES[1])[:4]
        for tool, args in (("bl-search-numbers", ()), ("bl-magic", ("-f", "ce"))):
            with self.subTest(tool=tool):
                r = _tools.run(tool, *args, input=data)
                self.assertEqual(r.returncode, 1)
                self.assertTrue(r.stdout.startswith(encode(VALUES[0])[:1]))  # what came before went on
                self.assertRegex(r.stderr.decode(),
                                 r"^-- (stdin: )?input ended partway through a value \(at byte \d+\)\n$")

    def test_malformed_input_names_the_corpus_reason(self):
        r = _tools.run("bl-search-entries", input=bytes.fromhex("9041623761a0"))
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stderr, b"-- malformed input: out-of-order at byte 3\n")

    def test_empty_input_is_silence(self):
        for tool in ("bl-search-numbers", "bl-magic"):
            with self.subTest(tool=tool):
                r = _tools.run(tool)
                self.assertEqual((r.returncode, r.stdout, r.stderr), (0, b"", b""))

    def test_take(self):
        data = encode_all(bl(f'"{i}"') for i in range(10))
        r = _tools.run("bl-search-numbers", "-n", "3", input=data)
        self.assertEqual(r.stdout, encode_all(bl(str(i)) for i in range(3)))
        r = _tools.run("bl-search-numbers", "--take:2", input=data)
        self.assertEqual(r.stdout, encode_all(bl(str(i)) for i in range(2)))


if __name__ == "__main__":
    unittest.main()
