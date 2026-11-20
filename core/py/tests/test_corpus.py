"""Every case in the shared corpus, all seven heads, three ways."""

import random
import unittest

import _path  # noqa: F401
import corpus
from bassline import (
    Decoder,
    DecodeError,
    Incomplete,
    List,
    ReadError,
    Reader,
    carrier,
    decode,
    encode,
    encode_all,
    read,
    read_all,
)


def name_of(case):
    return str(case.fields[0])


class ThreeWays(unittest.TestCase):
    def test_count_and_heads(self):
        heads = {}
        for c in corpus.cases:
            heads[c.head.name] = heads.get(c.head.name, 0) + 1
        self.assertEqual(set(heads), set(corpus.HEADS))
        self.assertEqual(len(corpus.cases), 150)
        self.assertEqual(heads, {"ce": 53, "reject": 28, "starved": 6, "reads": 17,
                                 "refuses": 33, "incomplete": 9, "document": 4})

    def test_blb_reads_back_as_the_cases(self):
        self.assertEqual(corpus.from_blb(), corpus.cases)

    def test_json_reads_back_as_the_cases(self):
        self.assertEqual(corpus.from_json(), corpus.cases)

    def test_json_with_members_shuffled(self):
        for seed in range(5):
            tree = carrier.load_tree(corpus.raw("corpus.json"))
            shuffled = corpus.shuffle_members(tree, random.Random(seed))
            self.assertEqual(shuffled, 10)
            self.assertEqual([carrier.from_carrier(c) for c in tree], corpus.cases)

    def test_reencoding_reproduces_the_blb(self):
        self.assertEqual(encode_all(corpus.cases), corpus.raw("corpus.blb"))

    def test_carrier_writes_what_it_reads(self):
        for c in corpus.cases:
            self.assertEqual(carrier.from_json(carrier.to_json(c)), c)
            self.assertEqual(carrier.from_json(carrier.to_json(c, indent=2)), c)

    def test_printing_reads_back(self):
        for c in corpus.cases:
            self.assertEqual(read(str(c)), c)


def feed_bytewise(data: bytes):
    """Feed one byte at a time: the values landed after each byte."""
    d = Decoder()
    landed = []
    for i in range(len(data)):
        landed.append(list(d.feed(data[i:i + 1])))
    return d, landed


class CE(unittest.TestCase):
    def test_encodes_and_decodes(self):
        for c in corpus.of("ce"):
            _, value, expected = c.fields
            with self.subTest(name_of(c)):
                self.assertEqual(encode(value), expected.value)
                self.assertEqual(decode(expected.value), value)
                self.assertEqual(decode(expected.value).ce, expected.value)

    def test_nothing_lands_before_the_last_byte(self):
        for c in corpus.of("ce"):
            _, value, expected = c.fields
            with self.subTest(name_of(c)):
                d, landed = feed_bytewise(expected.value)
                self.assertTrue(all(not got for got in landed[:-1]))
                self.assertEqual(landed[-1], [value])
                self.assertFalse(d.pending)
                self.assertEqual(list(d.finish()), [])

    def test_concatenated(self):
        values = [c.fields[1] for c in corpus.of("ce")]
        data = b"".join(c.fields[2].value for c in corpus.of("ce"))
        rng = random.Random(3)
        for _ in range(20):
            d = Decoder()
            got = []
            i = 0
            while i < len(data):
                n = rng.randint(1, 40)
                got.extend(d.feed(data[i:i + n]))
                i += n
            got.extend(d.finish())
            self.assertEqual(got, values)


class Reject(unittest.TestCase):
    def test_exact_reason(self):
        for c in corpus.of("reject"):
            _, data, reason = c.fields
            with self.subTest(name_of(c)):
                with self.assertRaises(DecodeError) as caught:
                    decode(data.value)
                self.assertEqual(caught.exception.reason, reason.name)
                self.assertEqual(caught.exception.reason.value, reason.name)

    def test_same_reason_one_byte_at_a_time(self):
        for c in corpus.of("reject"):
            _, data, reason = c.fields
            with self.subTest(name_of(c)):
                d = Decoder()
                err = None
                for i in range(len(data.value)):
                    try:
                        list(d.feed(data.value[i:i + 1]))
                    except DecodeError as e:
                        err = e
                        break
                self.assertIsNotNone(err, "refused before the input ended")
                self.assertEqual(err.reason, reason.name)
                self.assertEqual(err.offset, i, "refused at the byte that broke the rule")

    def test_refused_after_a_good_value(self):
        good = encode(List([1, 2]))
        for c in corpus.of("reject"):
            _, data, reason = c.fields
            with self.subTest(name_of(c)):
                d = Decoder().feed(good + data.value)
                landed = []
                with self.assertRaises(DecodeError) as caught:
                    for v in d:
                        landed.append(v)
                self.assertEqual(landed[0], List([1, 2]))
                self.assertEqual(caught.exception.reason, reason.name)
                self.assertGreaterEqual(caught.exception.offset, len(good))
                with self.assertRaises(DecodeError):  # and it stays refused
                    next(d.feed(good))


class Starved(unittest.TestCase):
    def test_waits_without_refusing(self):
        for c in corpus.of("starved"):
            _, data = c.fields
            with self.subTest(name_of(c)):
                d = Decoder()
                self.assertEqual(list(d.feed(data.value)), [])
                self.assertTrue(d.pending)
                _, landed = feed_bytewise(data.value)
                self.assertTrue(all(not got for got in landed))

    def test_one_shot_reports_incomplete(self):
        for c in corpus.of("starved"):
            _, data = c.fields
            with self.subTest(name_of(c)):
                with self.assertRaises(Incomplete):
                    decode(data.value)
                with self.assertRaises(Incomplete):
                    list(Decoder().feed(data.value).finish())


class Reads(unittest.TestCase):
    def test_reads(self):
        for c in corpus.of("reads"):
            text, value = c.fields
            with self.subTest(text.value):
                self.assertEqual(read(text.value), value)
                self.assertEqual(read(text.value.encode("utf-8")), value)


class Refuses(unittest.TestCase):
    def test_refused_not_incomplete(self):
        for c in corpus.of("refuses"):
            (text,) = c.fields
            with self.subTest(text.value):
                with self.assertRaises(ReadError):
                    read(text.value)

    def test_refused_as_documents_too(self):
        # every case but those about counting values is a syntax error
        # however many values the text holds, so a reader can't pass by
        # splitting a bad token into two good ones
        for c in corpus.of("refuses"):
            (text,) = c.fields
            with self.subTest(text.value):
                if text.value in ("", "1 2"):      # a document of none, or of two
                    read_all(text.value)
                    continue
                if text.value in ("1 [", "go !"):  # a document waiting on its second
                    with self.assertRaises(Incomplete):
                        read_all(text.value)
                    continue
                with self.assertRaises(ReadError):
                    read_all(text.value)
                r = Reader()
                with self.assertRaises(ReadError):
                    list(r.feed(text.value))
                    list(r.finish())


class IncompleteText(unittest.TestCase):
    def test_incomplete_not_refused(self):
        for c in corpus.of("incomplete"):
            (text,) = c.fields
            with self.subTest(text.value):
                with self.assertRaises(Incomplete):
                    read(text.value)

    def test_a_reader_keeps_waiting(self):
        for c in corpus.of("incomplete"):
            (text,) = c.fields
            with self.subTest(text.value):
                r = Reader()
                for ch in text.value:
                    list(r.feed(ch))   # never refused while text arrives
                with self.assertRaises(Incomplete):
                    list(r.finish())


class Document(unittest.TestCase):
    def test_documents(self):
        for c in corpus.of("document"):
            text, values = c.fields
            with self.subTest(text.value):
                self.assertEqual(List(read_all(text.value)), values)

    def test_documents_a_character_at_a_time(self):
        for c in corpus.of("document"):
            text, values = c.fields
            with self.subTest(text.value):
                r = Reader()
                got = []
                for ch in text.value:
                    got.extend(r.feed(ch))
                got.extend(r.finish())
                self.assertEqual(List(got), values)


class TheCorpusFileItself(unittest.TestCase):
    def test_reads_a_character_at_a_time(self):
        text = corpus.raw("corpus.bl").decode("utf-8")
        r = Reader()
        got = []
        for ch in text:
            got.extend(r.feed(ch))
        got.extend(r.finish())
        self.assertEqual(got, corpus.cases)

    def test_reads_in_utf8_byte_chunks(self):
        data = corpus.raw("corpus.bl")
        rng = random.Random(11)
        for _ in range(10):
            r = Reader()
            got = []
            i = 0
            while i < len(data):
                n = rng.randint(1, 50)
                got.extend(r.feed(data[i:i + n]))
                i += n
            got.extend(r.finish())
            self.assertEqual(got, corpus.cases)


if __name__ == "__main__":
    unittest.main()
