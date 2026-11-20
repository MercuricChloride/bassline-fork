"""Properties on seeded random values: every kind, marks, big integers,
long payloads, awkward text."""

import functools
import random
import unittest

import _path  # noqa: F401
from gen import Gen, item_boundaries, ref_cmp, truncation_prefixes
from bassline import (
    Decoder,
    DecodeError,
    Dict,
    Incomplete,
    ReadError,
    Reader,
    Set,
    carrier,
    decode,
    decode_all,
    encode,
    encode_all,
    frame_key,
    prefixes,
    pretty,
    read,
    read_all,
    under,
)

VALUES = Gen(42).values(400)
SMALL = [v for v in Gen(7).values(300, max_depth=3) if len(v.ce) < 400]


def sign(x: int) -> int:
    return (x > 0) - (x < 0)


class RoundTrips(unittest.TestCase):
    def test_encode_then_decode(self):
        for v in VALUES:
            b = encode(v)
            back = decode(b)
            self.assertEqual(back, v)
            self.assertEqual(back.ce, b)
            self.assertEqual(hash(back), hash(v))

    def test_print_then_read(self):
        for v in VALUES:
            text = str(v)
            self.assertNotIn("\n", text)
            self.assertNotIn("\r", text)
            self.assertEqual(read(text), v, text)

    def test_pretty_then_read(self):
        for v in VALUES[:150]:
            for width in (8, 40, 80):
                self.assertEqual(read(pretty(v, width)), v)

    def test_carrier(self):
        for v in VALUES:
            self.assertEqual(carrier.from_json(carrier.to_json(v)), v)
            self.assertEqual(carrier.from_carrier(carrier.to_carrier(v)), v)
        for v in VALUES[:100]:
            self.assertEqual(carrier.from_json(carrier.to_json(v, indent=1)), v)


class Concatenations(unittest.TestCase):
    def test_decode_all(self):
        self.assertEqual(decode_all(encode_all(VALUES)), VALUES)

    def test_one_byte_at_a_time(self):
        values = VALUES[:150]
        data = encode_all(values)
        d = Decoder()
        got = []
        for i in range(len(data)):
            got.extend(d.feed(data[i:i + 1]))
        got.extend(d.finish())
        self.assertEqual(got, values)

    def test_ragged_chunks(self):
        data = encode_all(VALUES)
        rng = random.Random(5)
        for top in (3, 64, 4096):
            d = Decoder()
            got = []
            i = 0
            while i < len(data):
                n = rng.randint(1, top)
                got.extend(d.feed(data[i:i + n]))
                i += n
            got.extend(d.finish())
            self.assertEqual(got, VALUES)

    def test_text_a_character_at_a_time(self):
        values = VALUES[:150]
        rng = random.Random(9)
        seps = [" ", "\n", "\t", " ; a comment\n", "\r\n"]
        text = "".join(str(v) + rng.choice(seps) for v in values)
        r = Reader()
        got = []
        for ch in text:
            got.extend(r.feed(ch))
        got.extend(r.finish())
        self.assertEqual(got, values)

    def test_text_in_utf8_byte_chunks(self):
        rng = random.Random(10)
        text = "\n".join(str(v) for v in VALUES)
        data = text.encode("utf-8")
        for top in (2, 7, 300):
            r = Reader()
            got = []
            i = 0
            while i < len(data):
                n = rng.randint(1, top)
                got.extend(r.feed(data[i:i + n]))
                i += n
            got.extend(r.finish())
            self.assertEqual(got, VALUES)

    def test_documents_without_separators_where_allowed(self):
        # frames and text end at their closing character, so they can touch
        # what follows, except a marked frame: a "!" touching a closed frame
        # would mark it from behind, which is refused
        values = [v for v in VALUES if v.is_frame or v.kind == 3][:100]
        text = "".join((" " if v.is_frame and v.mark else "") + str(v) for v in values)
        self.assertEqual(read_all(text), values)
        with self.assertRaises(ReadError):
            read_all("[a]!(b)")


class Order(unittest.TestCase):
    def test_order_is_the_structural_model(self):
        rng = random.Random(1)
        for _ in range(4000):
            a, b = rng.choice(VALUES), rng.choice(VALUES)
            self.assertEqual(sign(ref_cmp(a, b)), (a > b) - (a < b), f"{a} vs {b}")

    def test_sorted_is_byte_order_and_the_model(self):
        by_value = sorted(VALUES)
        self.assertEqual([v.ce for v in by_value], sorted(v.ce for v in VALUES))
        self.assertEqual(by_value, sorted(VALUES, key=functools.cmp_to_key(ref_cmp)))

    def test_equal_iff_same_bytes(self):
        rng = random.Random(2)
        for _ in range(4000):
            a, b = rng.choice(VALUES), rng.choice(VALUES)
            self.assertEqual(a == b, a.ce == b.ce)
            self.assertEqual(a != b, a.ce != b.ce)
            if a == b:
                self.assertEqual(hash(a), hash(b))

    def test_collections_canonical_whatever_the_insertion_order(self):
        rng = random.Random(4)
        for v in VALUES:
            if v.kind == 9:
                members = list(v)
                rng.shuffle(members)
                s = Set(members, mark=v.mark)
                self.assertEqual(s, v)
                self.assertEqual(list(s), sorted(members))
            elif v.kind == 8:
                items = list(v.items())
                rng.shuffle(items)
                d = Dict(items, mark=v.mark)
                self.assertEqual(d, v)
                self.assertEqual(list(d), sorted(k for k, _ in items))

    def test_values_as_python_dict_keys(self):
        table = {v: i for i, v in enumerate(VALUES)}
        for i, v in enumerate(VALUES):
            self.assertEqual(VALUES[table[decode(v.ce)]], v)


class Prefixes(unittest.TestCase):
    def test_truncations_are_prefixes(self):
        for v in SMALL:
            for q in truncation_prefixes(v):
                self.assertTrue(prefixes(q, v), f"{q} should prefix {v}")
                self.assertTrue(v.ce.startswith(frame_key(q)))

    def test_prefixes_is_exactly_truncation(self):
        rng = random.Random(6)
        pool = list(SMALL)
        for v in SMALL[:60]:
            pool.extend(truncation_prefixes(v))
        for v in SMALL:
            truncs = set(truncation_prefixes(v))
            for q in rng.sample(pool, 40) + list(truncs):
                expected = q in truncs
                self.assertEqual(prefixes(q, v), expected, f"{q} / {v}")
                self.assertEqual(v.ce.startswith(frame_key(q)), expected, f"{q} / {v}")

    def test_under_selects_by_bytes(self):
        for q in SMALL[:80]:
            self.assertEqual(list(under(q, SMALL)), [v for v in SMALL if prefixes(q, v)])


def outcome(d: Decoder, chunks):
    """What a decoder made of these chunks: the values, then the refusal
    or incompleteness, if any."""
    got = []
    try:
        for c in chunks:
            got.extend(d.feed(c))
        got.extend(d.finish())
        return got, None
    except DecodeError as e:
        return got, (e.reason, e.offset)
    except Incomplete:
        return got, "incomplete"


def corrupt(rng: random.Random, data: bytes) -> bytes:
    b = bytearray(data)
    for _ in range(rng.randint(1, 3)):
        op = rng.randrange(4)
        i = rng.randrange(len(b) + 1)
        if op == 0 and i < len(b):
            b[i] = rng.randrange(256)
        elif op == 1 and i < len(b):
            del b[i]
        elif op == 2:
            b.insert(i, rng.choice((0xA0, 0x10, 0x60, 0x37, rng.randrange(256))))
        else:
            del b[i:]
    return bytes(b)


class FirstFault(unittest.TestCase):
    """However the bytes are chunked, a decoder lands the same values and
    refuses with the same reason at the same byte, and that byte is the
    first one that broke a rule."""

    def test_chunking_never_changes_the_verdict(self):
        rng = random.Random(8)
        for v in SMALL[:200]:
            for _ in range(4):
                data = corrupt(rng, encode_all([v, rng.choice(SMALL)]))
                whole = outcome(Decoder(), [data])
                bytewise = outcome(Decoder(), [data[i:i + 1] for i in range(len(data))])
                cuts = sorted(rng.sample(range(len(data) + 1), min(4, len(data) + 1)))
                ragged = outcome(Decoder(), [data[a:b] for a, b in zip([0] + cuts, cuts + [len(data)])])
                self.assertEqual(whole, bytewise, data.hex())
                self.assertEqual(whole, ragged, data.hex())

    def test_refused_at_the_first_breaking_byte(self):
        rng = random.Random(12)
        refused = 0
        for v in SMALL[:200]:
            for _ in range(4):
                data = corrupt(rng, encode(v))
                _, fault = outcome(Decoder(), [data])
                if not isinstance(fault, tuple):
                    continue
                reason, at = fault
                refused += 1
                # everything before that byte is still acceptable so far
                before = Decoder().feed(data[:at])
                try:
                    list(before)
                except DecodeError as e:  # pragma: no cover - the failure itself
                    self.fail(f"refused at {e.offset} before {at}: {data.hex()}")
                # and that byte breaks the rule
                _, again = outcome(Decoder(), [data[:at + 1]])
                self.assertEqual(again, (reason, at), data.hex())
        self.assertGreater(refused, 300)


def _mismatch(a: bytes, b: bytes) -> int:
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return min(len(a), len(b))


class OrderFaults(unittest.TestCase):
    """Sets and dicts spelled with members out of order or repeated, at
    some depth: refused at the first byte where a member falls below its
    predecessor, or the last byte of a repeat, whatever the chunking."""

    def raw_set(self, rng, members, wrap):
        body = b"\x90" + b"".join(m.ce for m in members) + b"\xa0"
        prefix, suffix = wrap
        return prefix + body + suffix, len(prefix) + 1

    def test_order_and_duplicates(self):
        rng = random.Random(14)
        wraps = [(b"", b""), (b"\x60", b"\xa0"), (b"\x60\x60\x21\x31", b"\xa0\xa0"),
                 (b"\x80\x41\x6b", b"\xa0"), (b"\x70\x41\x66", b"\xa0")]
        seen = set()
        for _ in range(600):
            pool = rng.sample(SMALL, rng.randint(2, 5))
            members = list(pool)
            if rng.randrange(3) == 0:
                members.insert(rng.randrange(len(members) + 1), rng.choice(members))
            rng.shuffle(members)
            data, start = self.raw_set(rng, members, rng.choice(wraps))
            expected = None
            pos = start + len(members[0].ce)
            for prev, cur in zip(members, members[1:]):
                a, b = prev.ce, cur.ce
                if a == b:
                    expected = ("duplicate", pos + len(b) - 1)
                    break
                if b < a:
                    expected = ("out-of-order", pos + _mismatch(a, b))
                    break
                pos += len(b)
            whole = outcome(Decoder(), [data])
            bytewise = outcome(Decoder(), [data[i:i + 1] for i in range(len(data))])
            self.assertEqual(whole, bytewise)
            if expected is None:
                self.assertIsNone(whole[1])
            else:
                seen.add(expected[0])
                self.assertEqual(whole[1], expected, data.hex())
        self.assertEqual(seen, {"duplicate", "out-of-order"})

    def test_truncated_input_is_refused_once_order_breaks(self):
        # {b "a…} stops inside the second member's payload, yet text sorts
        # before symbols, so the header byte already broke the order
        with self.assertRaises(DecodeError) as caught:
            decode(bytes.fromhex("904162") + bytes.fromhex("3761"))
        self.assertEqual((caught.exception.reason, caught.exception.offset),
                         ("out-of-order", 3))
        # and with the same bytes in order it only waits
        with self.assertRaises(Incomplete):
            decode(bytes.fromhex("903162") + bytes.fromhex("4761"))


def depth_of(v) -> int:
    best = 0
    stack = [(v, 0)]
    while stack:
        x, d = stack.pop()
        if x.kind >= 6:
            d += 1
            best = max(best, d)
            for m in (y for kv in x.items() for y in kv) if x.kind == 8 else x:
                stack.append((m, d))
    return best


def first_limit_fault(ce: bytes, max_depth: int, cap: int):
    """Where a decoder with these limits must refuse ``ce``, by the rules
    written out: the depth limit at the header that passes it, the cap at
    the byte that shows the value passing it (a scalar's whole declared
    length counts once its length is read)."""
    i = depth = 0
    while i < len(ce):
        h = ce[i]
        tag, lb = h >> 4, h & 7
        if h == 0xA0 or tag == 1 or tag >= 6:
            if i + 1 > cap:
                return "too-large", i
            if tag >= 6 and h != 0xA0:
                if depth >= max_depth:
                    return "too-deep", i
                depth += 1
            elif h == 0xA0:
                depth -= 1
            i += 1
            continue
        if i + 1 > cap:
            return "too-large", i
        if lb < 7:
            hl, n, known = 1, lb, i
        elif ce[i + 1] < 255:
            hl, n, known = 2, ce[i + 1], i + 1
        else:
            hl, n, known = 6, int.from_bytes(ce[i + 2:i + 6], "big"), i + 5
        if i + hl + n > cap:
            return "too-large", known
        i += hl + n
    return None


class Limits(unittest.TestCase):
    def test_limits_refuse_exactly_by_the_rules(self):
        rng = random.Random(13)
        refused = 0
        for v in VALUES:
            ce = v.ce
            max_depth = rng.randint(0, 4)
            cap = rng.randint(1, max(2, len(ce) + 5))
            expected = first_limit_fault(ce, max_depth, cap)
            got, fault = outcome(Decoder(max_depth=max_depth, max_value_bytes=cap), [ce])
            if expected is None:
                self.assertEqual((got, fault), ([v], None))
                self.assertLessEqual(depth_of(v), max_depth)
            else:
                refused += 1
                self.assertEqual(fault, expected, str(v))
        self.assertGreater(refused, 100)


if __name__ == "__main__":
    unittest.main()
