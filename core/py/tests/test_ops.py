"""Walking, folding, rebuilding and prefixes."""

import unittest

import _path  # noqa: F401
from gen import Gen
from bassline import (
    Integer,
    List,
    NotHeld,
    bl,
    carrier,
    decode,
    fold,
    frame_key,
    prefixes,
    pretty,
    read,
    sym,
    transform,
    under,
    walk,
)

VALUES = Gen(31).values(200)


class Walk(unittest.TestCase):
    def test_order(self):
        v = bl("(f [1 2] {a: b})")
        self.assertEqual([str(x) for x in walk(v)],
                         ["(f [1 2] {a: b})", "f", "[1 2]", "1", "2", "{a: b}", "a", "b"])

    def test_an_atom(self):
        self.assertEqual(list(walk(Integer(1))), [Integer(1)])


class Fold(unittest.TestCase):
    def test_the_encoding_is_a_fold(self):
        def ce(x, rs):
            return x.ce if x.is_atom else bytes([x.ce[0]]) + b"".join(rs) + b"\xa0"
        for v in VALUES:
            self.assertEqual(fold(v, ce), v.ce)

    def test_counting(self):
        for v in VALUES:
            self.assertEqual(fold(v, lambda x, rs: 1 + sum(rs)), len(list(walk(v))))


class Transform(unittest.TestCase):
    def test_bottom_up(self):
        v = bl("!(sum [1 2 {x: 3}] go!)")
        bumped = transform(v, lambda x: Integer(x.value + 1, mark=x.mark)
                           if x.kind == 2 else x)
        self.assertEqual(bumped, bl("!(sum [2 3 {x: 4}] go!)"))

    def test_identity_keeps_the_value(self):
        for v in VALUES:
            self.assertIs(transform(v, lambda x: x), v)

    def test_members_that_become_equal(self):
        self.assertEqual(transform(bl("{1 2 3}"), lambda x: Integer(0) if x.kind == 2 else x),
                         bl("{0}"))

    def test_host_results_are_read(self):
        self.assertEqual(transform(bl("[a b]"), lambda x: x.name if x.kind == 4 else x),
                         bl('["a" "b"]'))


class Prefixes(unittest.TestCase):
    def test_examples(self):
        yes = [("(signed [1 2])", "(signed [1 2 3] x)"), ("[]", "[1]"), ("[1]", "[1 2]"),
               ("[[1]]", "[[1 2] 3]"), ("{a: [1]}", "{a: [1 2] b: 3}"), ("{1 2}", "{1 2 3}"),
               ("{}", "{1}"), ("{:}", "{a: 1}"), ("x", "x"), ("!(f)", "!(f 1)"),
               ("(f [])", "(f [] 2)")]
        no = [("[1]", "[12]"), ("{1 3}", "{1 2 3}"), ("(f)", "!(f 1)"), ("[a]", "(a)"),
              ("x", "x!"), ("[1 2]", "[1]"), ("{a: 1}", "{a: 12}"), ("{b: 1}", "{a: 1 b: 1}"),
              ("[[1] 2]", "[[1 2] 2]")]
        for a, b in yes:
            with self.subTest(f"{a} prefixes {b}"):
                self.assertTrue(prefixes(read(a), read(b)))
                self.assertTrue(read(b).ce.startswith(frame_key(read(a))))
        for a, b in no:
            with self.subTest(f"{a} does not prefix {b}"):
                self.assertFalse(prefixes(read(a), read(b)))
                self.assertFalse(read(b).ce.startswith(frame_key(read(a))))

    def test_frame_key(self):
        self.assertEqual(frame_key(bl("(person)")), bytes.fromhex("7046706572736f6e"))
        self.assertEqual(frame_key(bl("go")), bl("go").ce)
        self.assertEqual(frame_key(bl("[[1]]")), bytes.fromhex("60602131"))
        self.assertEqual(frame_key(bl("[0xa0]")), bytes.fromhex("6051a0"))  # payload bytes stay

    def test_under(self):
        facts = [bl(t) for t in ("(person ada)", "(person bob 1)", "(place x)", "person",
                                 "!(person ada)", "(person)")]
        self.assertEqual([str(f) for f in under(bl("(person)"), facts)],
                         ["(person ada)", "(person bob 1)", "(person)"])

    def test_reflexive(self):
        for v in VALUES:
            self.assertTrue(prefixes(v, v))


class Depth(unittest.TestCase):
    def test_deep_values_never_reach_the_call_stack(self):
        v = List()
        for _ in range(20000):
            v = List._trusted((v,))
        self.assertEqual(len(v.ce), 40002)
        self.assertEqual(decode(v.ce, max_depth=20001), v)
        self.assertEqual(sum(1 for _ in walk(v)), 20001)
        self.assertEqual(fold(v, lambda x, rs: 1 + sum(rs)), 20001)
        self.assertTrue(prefixes(v, v))
        self.assertEqual(len(frame_key(v)), 20001)
        self.assertEqual(read(str(v), max_depth=20001), v)
        self.assertIs(transform(v, lambda x: x), v)
        self.assertEqual(hash(v), hash(decode(v.ce, max_depth=20001)))
        self.assertTrue(str(v).startswith("[[[["))
        self.assertEqual(v, read(repr(v)[4:-2], max_depth=20001))
        import pickle
        self.assertEqual(pickle.loads(pickle.dumps(v)), v)
        self.assertEqual(read(pretty(v), max_depth=20001), v)
        self.assertEqual(read(pretty(bl("(f)")), max_depth=2), bl("(f)"))
        text = carrier.to_json(v)
        try:  # Python's json module recurses; deep enough, it refuses
            self.assertEqual(carrier.from_json(text), v)
        except NotHeld:
            pass
        self.assertEqual(carrier.from_carrier(carrier.to_carrier(v)), v)


if __name__ == "__main__":
    unittest.main()
