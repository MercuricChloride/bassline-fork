"""The canonical encoding: tier edges, limits, the first fault, a decoder's
life."""

import io
import unittest

import _path  # noqa: F401
from bassline import (
    DEFAULT_MAX_DEPTH,
    Bytes,
    Decoder,
    DecodeError,
    Incomplete,
    Integer,
    List,
    Reason,
    Text,
    decode,
    decode_all,
    encode,
    encode_all,
    iterdecode,
)


def refusal(data: bytes, **limits):
    with unittest.TestCase().assertRaises(DecodeError) as caught:
        decode(data, **limits)
    return caught.exception.reason.value, caught.exception.offset


class LengthTiers(unittest.TestCase):
    def test_header_forms_at_the_edges(self):
        for n, header in ((0, "50"), (6, "56"), (7, "5707"), (254, "57fe"),
                          (255, "57ff000000ff"), (256, "57ff00000100"),
                          (65536, "57ff00010000")):
            b = bytes(n)
            ce = encode(Bytes(b))
            self.assertEqual(ce[:len(header) // 2].hex(), header, n)
            self.assertEqual(len(ce), len(header) // 2 + n)
            self.assertEqual(decode(ce), Bytes(b))

    def test_longer_forms_are_refused(self):
        self.assertEqual(refusal(bytes.fromhex("3706") + b"abcdef"), ("non-minimal-length", 1))
        self.assertEqual(refusal(bytes.fromhex("3700")), ("non-minimal-length", 1))
        self.assertEqual(refusal(bytes.fromhex("37ff000000fe") + b"a" * 254),
                         ("non-minimal-length", 5))
        self.assertEqual(refusal(bytes.fromhex("37ff00000007") + b"a" * 7),
                         ("non-minimal-length", 5))
        # 255 has no one-byte form at all: 0xff introduces the four-byte one
        self.assertEqual(decode(bytes.fromhex("37ff000000ff") + b"a" * 255), Text("a" * 255))

    def test_text_tiers_count_utf8_bytes(self):
        self.assertEqual(encode(Text("\u00e9" * 3))[0], 0x36)       # 6 bytes inline
        self.assertEqual(encode(Text("\u00e9" * 3 + "a"))[:2].hex(), "3707")


class Integers(unittest.TestCase):
    def test_boundaries(self):
        for n in (0, -1, 9, 10, -10, 2**63 - 1, -2**63, 2**63, 2**64, -(2**64)):
            ce = encode(Integer(n))
            self.assertEqual(ce[1 if len(str(n)) < 7 else 2:].decode(), str(n))
            self.assertEqual(decode(ce).value, n)

    def test_spelling_faults_at_the_byte(self):
        self.assertEqual(refusal(bytes.fromhex("20")), ("bad-integer", 0))         # no digits
        self.assertEqual(refusal(bytes.fromhex("212d")), ("bad-integer", 1))       # "-"
        self.assertEqual(refusal(bytes.fromhex("222d30")), ("bad-integer", 2))     # "-0"
        self.assertEqual(refusal(bytes.fromhex("23303037")), ("bad-integer", 1))   # "007"
        self.assertEqual(refusal(bytes.fromhex("23313a37")), ("bad-integer", 2))   # "1:7"
        self.assertEqual(refusal(bytes.fromhex("222b35")), ("bad-integer", 1))     # "+5"


class Utf8(unittest.TestCase):
    def test_faults_at_the_byte(self):
        self.assertEqual(refusal(bytes.fromhex("31ff")), ("bad-utf8", 1))
        self.assertEqual(refusal(bytes.fromhex("32c080")), ("bad-utf8", 1))        # overlong lead
        self.assertEqual(refusal(bytes.fromhex("33eda080")), ("bad-utf8", 2))      # surrogate
        self.assertEqual(refusal(bytes.fromhex("33e228a1")), ("bad-utf8", 2))
        self.assertEqual(refusal(bytes.fromhex("3361e282")), ("bad-utf8", 2))      # runs past the end
        self.assertEqual(refusal(bytes.fromhex("34f4908080")), ("bad-utf8", 2))    # past U+10FFFF
        self.assertEqual(refusal(bytes.fromhex("44f0808080")), ("bad-utf8", 2))    # in a symbol

    def test_good_text_split_anywhere(self):
        t = Text("a\u00e9\u20ac\U0001F600" * 30)
        ce = encode(t)
        for cut in range(len(ce)):
            d = Decoder()
            self.assertEqual(list(d.feed(ce[:cut])), [])
            self.assertEqual(list(d.feed(ce[cut:])), [t])


class FirstFault(unittest.TestCase):
    def test_the_first_byte_wins(self):
        # a bad integer before an invalid tag
        self.assertEqual(refusal(bytes.fromhex("60222d3000")), ("bad-integer", 3))
        # a set member falling below its predecessor before its own bad integer
        self.assertEqual(refusal(bytes.fromhex("90602132a0602131222d30a0a0")), ("out-of-order", 7))
        # a member already above its predecessor, then a bad integer inside it
        self.assertEqual(refusal(bytes.fromhex("90602131a060222d30a0a0")), ("bad-integer", 8))

    def test_order_on_the_bytes(self):
        self.assertEqual(refusal(bytes.fromhex("90426162426161a0")), ("out-of-order", 6))
        self.assertEqual(refusal(bytes.fromhex("9041614161a0")), ("duplicate", 4))
        self.assertEqual(refusal(bytes.fromhex("9060a060a0a0")), ("duplicate", 4))
        self.assertEqual(refusal(bytes.fromhex("80416121314161a0")), ("duplicate", 6))
        # shorter frames sort after longer ones they prefix
        self.assertEqual(decode(bytes.fromhex("906041614162a0604161a0a0")),
                         decode(encode(decode(bytes.fromhex("906041614162a0604161a0a0")))))
        self.assertEqual(refusal(bytes.fromhex("90604161a06041614162a0a0")), ("out-of-order", 8))

    def test_a_value_breaking_its_own_rule_outranks_its_order_at_the_same_byte(self):
        self.assertEqual(refusal(bytes.fromhex("90416200")), ("invalid-tag", 3))
        self.assertEqual(refusal(bytes.fromhex("90416211")), ("length-bits", 3))

    def test_the_end_byte(self):
        self.assertEqual(refusal(bytes.fromhex("70a0")), ("empty-record", 1))
        self.assertEqual(refusal(bytes.fromhex("804161a0")), ("stranded-key", 3))
        self.assertEqual(refusal(bytes.fromhex("a0")), ("end-at-top", 0))
        self.assertEqual(refusal(bytes.fromhex("60a8")), ("end-with-bits", 1))


class Limits(unittest.TestCase):
    def nested(self, depth: int) -> bytes:
        return b"\x60" * depth + b"\xa0" * depth

    def test_depth(self):
        self.assertEqual(DEFAULT_MAX_DEPTH, 64)
        self.assertEqual(len(decode_all(self.nested(64))), 1)
        self.assertEqual(refusal(self.nested(65)), ("too-deep", 64))
        self.assertEqual(refusal(self.nested(3), max_depth=2), ("too-deep", 2))
        self.assertEqual(decode(bytes.fromhex("2131"), max_depth=0), Integer(1))
        self.assertEqual(refusal(bytes.fromhex("60a0"), max_depth=0), ("too-deep", 0))

    def test_bytes_toward_one_value(self):
        v = List([1, 2, 3])
        ce = encode(v)
        self.assertEqual(decode(ce, max_value_bytes=len(ce)), v)
        self.assertEqual(refusal(ce, max_value_bytes=len(ce) - 1), ("too-large", len(ce) - 1))
        # the cap is per value: many values may each fit
        self.assertEqual(decode_all(ce * 10, max_value_bytes=len(ce)), [v] * 10)

    def test_a_declared_length_is_refused_before_its_payload(self):
        d = Decoder(max_value_bytes=1000)
        with self.assertRaises(DecodeError) as caught:
            list(d.feed(bytes.fromhex("37ff00100000")))   # declares 1 MiB, sends none
        self.assertEqual((caught.exception.reason, caught.exception.offset), ("too-large", 5))
        d = Decoder()
        with self.assertRaises(DecodeError) as caught:
            list(d.feed(bytes.fromhex("37ffffffffff")))   # declares 4 GiB
        self.assertEqual(caught.exception.reason, Reason.TOO_LARGE)

    def test_one_shot_admits_what_it_was_handed(self):
        big = Bytes(bytes(2000))
        self.assertEqual(decode(encode(big)), big)
        d = Decoder(max_value_bytes=1000)
        with self.assertRaises(DecodeError):
            list(d.feed(encode(big)))


class DecodersLife(unittest.TestCase):
    def test_values_before_a_fault_come_first(self):
        d = Decoder().feed(encode_all([1, 2]) + b"\x00" + encode(3))
        self.assertEqual(next(d), Integer(1))
        self.assertEqual(next(d), Integer(2))
        with self.assertRaises(DecodeError) as first:
            next(d)
        self.assertEqual(first.exception.offset, 4)

    def test_once_failed_stays_failed(self):
        d = Decoder()
        with self.assertRaises(DecodeError) as first:
            list(d.feed(b"\x00"))
        for _ in range(3):
            with self.assertRaises(DecodeError) as again:
                list(d.feed(encode(1)))
            self.assertIs(again.exception, first.exception)
        with self.assertRaises(DecodeError) as at_end:
            list(d.finish())
        self.assertIs(at_end.exception, first.exception)

    def test_finish(self):
        d = Decoder()
        list(d.feed(encode(1) + b"\x60\x21"))
        self.assertTrue(d.pending)
        with self.assertRaises(Incomplete) as caught:
            list(d.finish())
        self.assertEqual(caught.exception.offset, 4)
        with self.assertRaises(ValueError):
            d.feed(b"\xa0")
        self.assertEqual(list(Decoder().finish()), [])

    def test_one_shot(self):
        with self.assertRaises(Incomplete):
            decode(b"")
        self.assertEqual(decode_all(b""), [])
        with self.assertRaises(DecodeError) as caught:
            decode(encode_all([1, 2]))
        self.assertEqual((caught.exception.reason, caught.exception.offset), ("trailing-bytes", 2))
        # a fault after the first value outranks there merely being more
        self.assertEqual(refusal(bytes.fromhex("60a0a0")), ("end-at-top", 2))

    def test_offsets_are_input_offsets_across_compaction(self):
        good = encode_all(range(5000))
        d = Decoder()
        n = 0
        for i in range(0, len(good), 7):
            n += len(list(d.feed(good[i:i + 7])))
        self.assertEqual(n, 5000)
        with self.assertRaises(DecodeError) as caught:
            list(d.feed(b"\xb0"))
        self.assertEqual(caught.exception.offset, len(good))

    def test_iterdecode_from_a_file(self):
        values = [Integer(i) for i in range(100)] + [Text("x" * 300)]
        f = io.BytesIO(encode_all(values))
        self.assertEqual(list(iterdecode(iter(lambda: f.read(5), b""))), values)
        with self.assertRaises(Incomplete):
            list(iterdecode([b"\x60"]))

    def test_any_buffer(self):
        ce = encode([1, "two"])
        self.assertEqual(decode(bytearray(ce)), decode(memoryview(ce)))


if __name__ == "__main__":
    unittest.main()
