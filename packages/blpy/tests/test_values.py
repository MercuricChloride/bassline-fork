"""Values as Python objects: construction, refusals, protocols, readings."""

import copy
import pickle
import unittest
from collections import OrderedDict
from dataclasses import dataclass

import _path  # noqa: F401
from bassline import (
    Bytes,
    Dict,
    Integer,
    Kind,
    List,
    Nil,
    NotHeld,
    Reading,
    Record,
    Set,
    Symbol,
    Text,
    Value,
    bl,
    decode,
    encode,
    mark,
    nil,
    plain,
    rec,
    sym,
    symbol_keys,
    symbolic,
    to_python,
    to_value,
    unmark,
)


class HostValuesThatAreNotValues(unittest.TestCase):
    def test_bool_is_refused_before_int(self):
        for b in (True, False):
            with self.assertRaises(NotHeld):
                to_value(b)
            with self.assertRaises(NotHeld):
                Integer(b)
            with self.assertRaises(NotHeld):
                List([1, b])

    def test_floats_are_refused(self):
        for f in (1.0, 0.5, float("nan"), float("inf"), -0.0, 1j):
            with self.assertRaises(NotHeld):
                to_value(f)
        with self.assertRaises(NotHeld):
            Integer(1.0)

    def test_refusal_is_both_type_and_value_error(self):
        with self.assertRaises(TypeError):
            to_value(True)
        with self.assertRaises(ValueError):
            to_value(1.5)

    def test_refused_and_incomplete_are_apart(self):
        from bassline import DecodeError, Incomplete, ReadError, Refused, decode, read
        for err in (DecodeError, ReadError, NotHeld):
            self.assertTrue(issubclass(err, Refused))
        self.assertFalse(issubclass(Incomplete, Refused))
        with self.assertRaises(Incomplete):
            try:
                decode(b"\x60")
            except Refused:  # pragma: no cover - the point of the test
                self.fail("a prefix was caught as a refusal")
        with self.assertRaises(Refused):
            read("(]")

    def test_lone_surrogates_are_refused(self):
        for s in ("\ud800", "a\udfffb", "\udc80"):
            with self.assertRaises(NotHeld):
                Text(s)
            with self.assertRaises(NotHeld):
                Symbol(s)
            with self.assertRaises(NotHeld):
                to_value(s)

    def test_unknown_host_types_are_refused(self):
        class Thing:
            pass
        with self.assertRaises(NotHeld):
            to_value(Thing())
        with self.assertRaises(NotHeld):
            to_value(object())

    def test_cycles_are_refused(self):
        a = [1]
        a.append(a)
        with self.assertRaises(NotHeld):
            to_value(a)
        d = {}
        d["self"] = d
        with self.assertRaises(NotHeld):
            to_value(d)

    def test_shared_but_acyclic_is_fine(self):
        shared = [1, 2]
        self.assertEqual(to_value([shared, shared]), bl("[[1 2] [1 2]]"))


class NotIntNotStr(unittest.TestCase):
    def test_values_never_equal_host_objects(self):
        self.assertNotEqual(Integer(1), 1)
        self.assertNotEqual(Integer(1), True)
        self.assertNotEqual(Integer(1), 1.0)
        self.assertNotEqual(Text("a"), "a")
        self.assertNotEqual(Bytes(b"a"), b"a")
        self.assertNotEqual(nil, None)
        self.assertFalse(isinstance(Integer(1), int))
        self.assertFalse(isinstance(Text("a"), str))

    def test_one_true_and_one_point_oh_stay_apart_as_keys(self):
        table = {Integer(1): "one"}
        self.assertNotIn(1, table)
        self.assertNotIn(True, table)
        self.assertIn(Integer(1), table)

    def test_ordering_with_host_objects_is_a_type_error(self):
        with self.assertRaises(TypeError):
            Integer(1) < 2  # noqa: B015

    def test_kinds_are_distinct(self):
        self.assertNotEqual(Text("go"), Symbol("go"))
        self.assertFalse(isinstance(Symbol("go"), Text))
        self.assertNotEqual(List([1]), Record(1))
        self.assertNotEqual(Set(), Dict())
        self.assertNotEqual(bl("[]"), bl("{}"))


class Integers(unittest.TestCase):
    def test_any_size(self):
        for n in (0, 1, -1, 2**63 - 1, -2**63, 2**64, -2**64, 10**100, -(10**5000)):
            v = Integer(n)
            self.assertEqual(v.value, n)
            self.assertEqual(int(v), n)
            self.assertEqual(decode(encode(v)).value, n)
            self.assertEqual(bl(str(v)), v)

    def test_past_the_interpreter_digit_limit(self):
        n = 7 * 10**6000 + 3
        v = Integer(n)
        self.assertEqual(len(v.spelling), 6001)
        self.assertEqual(decode(v.ce).value, n)
        self.assertEqual(bl(str(v)).value, n)

    def test_canonical_spellings_only(self):
        self.assertEqual(Integer.parse("-42"), Integer(-42))
        for bad in ("007", "-0", "+5", " 5", "5 ", "1_000", "", "-", "\u0663", "1.0"):
            with self.assertRaises(NotHeld, msg=bad):
                Integer.parse(bad)

    def test_index(self):
        self.assertEqual([10, 20, 30][Integer(1)], 20)


class Text_(unittest.TestCase):
    def test_never_normalised(self):
        nfc, nfd = Text("\u00e9"), Text("e\u0301")
        self.assertNotEqual(nfc, nfd)
        self.assertEqual(len(Set([nfc, nfd])), 2)
        self.assertEqual(decode(encode(nfd)).value, "e\u0301")
        self.assertEqual(bl(str(nfd)).value, "e\u0301")
        self.assertNotEqual(Symbol("\u00e9"), Symbol("e\u0301"))

    def test_str_is_the_textual_syntax(self):
        self.assertEqual(str(Text('say "hi"\n')), '"say \\"hi\\"\\n"')
        self.assertEqual(str(Symbol("go")), "go")
        self.assertEqual(str(Symbol("has space")), "'has space'")
        self.assertEqual(str(Text("hi").marked()), '"hi"!')
        self.assertEqual(f"{rec(sym.f, 1)}", "(f 1)")
        self.assertEqual(Text("hi").value, "hi")

    def test_repr_reads_back(self):
        v = bl('(person {name: "Ada" tags: {x y} note: \'a b\'!})')
        self.assertEqual(eval(repr(v), {"bl": bl}), v)


class Marks(unittest.TestCase):
    def test_every_kind_carries_a_mark(self):
        for v in (nil, Integer(1), Text("t"), Symbol("s"), Bytes(b"b"),
                  List([1]), Record(sym.h), Dict({1: 2}), Set([1])):
            m = v.marked()
            self.assertTrue(m.mark)
            self.assertNotEqual(m, v)
            self.assertEqual(m.unmarked(), v)
            self.assertEqual(m.ce[0], v.ce[0] | 0x08)
            self.assertEqual(m.ce[1:], v.ce[1:])
            self.assertEqual(decode(m.ce), m)

    def test_the_mark_does_not_flow_into_children(self):
        v = bl("!(go [1 2] {a: b})")
        self.assertTrue(v.mark)
        self.assertFalse(any(m.mark for m in v))

    def test_parts_of_a_marked_value_are_not_marked(self):
        v = bl("![1 2 3]")
        self.assertFalse(v[1:].mark)
        self.assertFalse((v + [4]).mark)
        self.assertFalse(List(v).mark)

    def test_helpers(self):
        self.assertEqual(mark(sym.go), bl("go!"))
        self.assertEqual(unmark(bl("go!")), sym.go)
        self.assertEqual(mark([1]), bl("![1]"))
        self.assertTrue(Nil(mark=True).mark)


class Frames(unittest.TestCase):
    def test_list_is_a_sequence(self):
        v = List([1, "two", [3]])
        self.assertEqual(len(v), 3)
        self.assertEqual(v[0], Integer(1))
        self.assertEqual(v[-1], List([3]))
        self.assertEqual(v[1:], List(["two", [3]]))
        self.assertIn(1, v)
        self.assertIn(Text("two"), v)
        self.assertEqual(list(reversed(v))[0], List([3]))
        self.assertEqual(v + [4], List([1, "two", [3], 4]))
        self.assertEqual([0] + v, List([0, 1, "two", [3]]))

    def test_list_refuses_a_string_as_its_members(self):
        with self.assertRaises(NotHeld):
            List("abc")
        with self.assertRaises(NotHeld):
            Set(b"abc")

    def test_record(self):
        r = rec(sym.point, 1, 2)
        self.assertEqual(r.head, sym.point)
        self.assertEqual(r.fields, (Integer(1), Integer(2)))
        self.assertEqual(r[0], sym.point)
        self.assertEqual(len(r), 3)
        self.assertEqual(r, Record(sym.point, 1, 2))
        self.assertEqual(r, bl("(point 1 2)"))
        with self.assertRaises(TypeError):
            Record()  # a record has a head

    def test_dict_is_a_mapping(self):
        d = bl('{name: "Ada" 1: one "1": text-one}')
        self.assertEqual(d[sym.name], Text("Ada"))
        self.assertEqual(d[1], sym.one)
        self.assertEqual(d["1"], sym("text-one"))
        self.assertNotIn("name", d)  # a host str is text; the key is a symbol
        self.assertIn(sym.name, d)
        self.assertEqual(len(d), 3)
        self.assertEqual(list(d), sorted(d))  # canonical order
        self.assertEqual(dict(d.items())[sym.name], Text("Ada"))

    def test_nil_and_silence_stay_apart(self):
        d = bl("{a: nil}")
        self.assertEqual(d[sym.a], nil)
        self.assertIsNone(d.get(sym.b))
        self.assertEqual(d.get(sym.a), nil)
        with self.assertRaises(KeyError):
            d[sym.b]
        self.assertIsNotNone(d.get(sym.a))

    def test_dict_keys_must_be_given_once(self):
        with self.assertRaises(NotHeld):
            Dict([(1, "a"), (1, "b")])
        with self.assertRaises(NotHeld):
            symbolic({"a": 1, Symbol("a"): 2})

    def test_dict_updates_make_new_values(self):
        d = bl("{a: 1}")
        e = d | {sym.b: 2}
        self.assertEqual(e, bl("{a: 1 b: 2}"))
        self.assertEqual(d, bl("{a: 1}"))
        self.assertEqual(e.without(sym.a), bl("{b: 2}"))
        self.assertEqual(d.map(lambda v: Integer(v.value * 10)), bl("{a: 10}"))

    def test_set_is_a_set(self):
        s = Set([3, 1, 2, 1])
        self.assertEqual(len(s), 3)
        self.assertEqual(list(s), [Integer(1), Integer(2), Integer(3)])
        self.assertIn(2, s)
        self.assertEqual(s | Set([4]), Set([1, 2, 3, 4]))
        self.assertEqual(s & Set([2, 9]), Set([2]))
        self.assertEqual(s - Set([1]), Set([2, 3]))
        self.assertTrue(Set([1]).issubset(s))
        self.assertTrue(s.issuperset([1, 2]))

    def test_less_than_is_canonical_order_even_for_sets(self):
        a, b = Set([1, 2]), Set([1])
        self.assertTrue(a < b)  # {1 2} sorts before {1}: the shorter frame is after
        self.assertFalse(b.issuperset(a))

    def test_immutable(self):
        v = List([1])
        with self.assertRaises(AttributeError):
            v.x = 1
        with self.assertRaises(AttributeError):
            v._m = ()
        with self.assertRaises(TypeError):
            v[0] = 2
        with self.assertRaises(TypeError):
            Value()

    def test_copy_and_pickle(self):
        v = bl('(msg "hello" 42 {k: v} go! 0xff)')
        self.assertIs(copy.copy(v), v)
        self.assertIs(copy.deepcopy(v), v)
        self.assertEqual(pickle.loads(pickle.dumps(v)), v)


class PatternMatching(unittest.TestCase):
    def describe(self, v):
        match v:
            case Nil():
                return "nil"
            case Integer(0):
                return "zero"
            case Integer(n) if n < 0:
                return f"negative {n}"
            case Text(s):
                return f"text {s}"
            case Symbol("go", mark=True):
                return "go!"
            case Symbol(name):
                return f"symbol {name}"
            case Record(Symbol("point"), (Integer(x), Integer(y))):
                return f"point {x},{y}"
            case Record(Symbol("person"), (Dict() as d, *_)):
                return f"person {d[sym.name].value}"
            case List([first, *rest]):
                return f"list of {1 + len(rest)} from {first}"
            case Set(members):
                return f"set of {len(members)}"
            case {sym.k: Text(t)}:
                return f"k is {t}"
        return "other"

    def test_match(self):
        cases = {
            "nil": "nil", "0": "zero", "-3": "negative -3", '"hi"': "text hi",
            "go!": "go!", "go": "symbol go", "(point 1 2)": "point 1,2",
            '(person {name: "Ada"})': "person Ada", "[a b c]": "list of 3 from a",
            "{a b}": "set of 2", '{k: "v"}': "k is v", "0x00": "other",
        }
        for text, expected in cases.items():
            self.assertEqual(self.describe(bl(text)), expected, text)


class ReadingsIn(unittest.TestCase):
    def test_default(self):
        v = to_value({"a": [1, b"\x00", None], 2: {3, 4}, (5, 6): frozenset()})
        self.assertEqual(v, bl('{"a": [1 0x00 nil] 2: {3 4} [5 6]: {}}'))

    def test_subclasses_follow_their_base(self):
        self.assertEqual(to_value(OrderedDict([("b", 1), ("a", 2)])), bl('{"a": 2 "b": 1}'))

    def test_siblings(self):
        self.assertEqual(symbolic(["a", {"b": "c"}]), bl("[a {b: c}]"))
        self.assertEqual(symbol_keys({"name": "Ada", "tags": ["x"]}),
                         bl('{name: "Ada" tags: ["x"]}'))

    def test_a_sibling_from_but(self):
        from decimal import Decimal

        def dec(x, read):
            if not x.is_finite():
                raise NotHeld(f"{x} has no (dec m e) form")
            sign, digits, exp = x.as_tuple()
            m = int("".join(map(str, digits)))
            if sign and not m:
                raise NotHeld(f"{x} has no (dec m e) form: its sign would be lost")
            return rec(sym.dec, -m if sign else m, exp)

        decimals = to_value.but({Decimal: dec}, "decimals")
        self.assertEqual(decimals([Decimal("1.5")]), bl("[(dec 15 -1)]"))
        self.assertEqual(decimals(Decimal("-1.50")), bl("(dec -150 -2)"))
        for x in ("-0", "-0.0", "NaN", "Infinity", "-Infinity"):
            with self.assertRaises(NotHeld, msg=x):
                decimals(Decimal(x))
        with self.assertRaises(NotHeld):
            to_value(Decimal("1.5"))

    def test_host_types_can_declare_a_reading(self):
        @dataclass
        class Point:
            x: int
            y: int

            def __bassline__(self):
                return rec(sym.point, self.x, self.y)

        self.assertEqual(to_value([Point(1, 2)]), bl("[(point 1 2)]"))
        self.assertEqual(List([Point(3, 4)]), bl("[(point 3 4)]"))
        # a reading's own rule comes first
        other = to_value.but({Point: lambda p, read: Text("a point")})
        self.assertEqual(other(Point(1, 2)), Text("a point"))

    def test_a_rule_must_give_a_value(self):
        bad = Reading({int: lambda x, read: x})
        with self.assertRaises(TypeError):
            bad(1)


class ReadingsOut(unittest.TestCase):
    def test_default(self):
        v = bl('{"a": [1 0x00 nil] 2: {3 [4 5]} [6]: "x"}')
        self.assertEqual(to_python(v), {"a": [1, b"\x00", None], 2: frozenset({3, (4, 5)}),
                                        (6,): "x"})

    def test_refuses_what_python_cannot_hold(self):
        for text in ("go", "(f)", "1!", "[1 x]", "{{:}: 1}", "{{a: 1}}"):
            with self.assertRaises(NotHeld, msg=text):
                to_python(bl(text))

    def test_plain_reads_symbols_as_str(self):
        self.assertEqual(plain(bl("[go {a: b}]")), ["go", {"a": "b"}])
        with self.assertRaises(NotHeld):
            plain(bl("go!"))

    def test_plain_never_drops_an_entry(self):
        for text in ('{a: 1 "a": 2}', '{a "a"}', '{[a] ["a"]}'):
            with self.assertRaises(NotHeld, msg=text):
                plain(bl(text))

    def test_round_trip_through_python(self):
        data = {"name": "Ada", "born": 1815, "tags": ["x", "y"], "raw": b"\x01",
                "none": None, "set": frozenset({1, 2})}
        self.assertEqual(to_python(to_value(data)), {**data, "tags": ["x", "y"]})


class Kinds(unittest.TestCase):
    def test_kind_numbers_are_tags(self):
        for v, k in ((nil, 1), (Integer(1), 2), (Text(""), 3), (Symbol("s"), 4),
                     (Bytes(b""), 5), (List(), 6), (Record(1), 7), (Dict(), 8), (Set(), 9)):
            self.assertEqual(v.kind, Kind(k))
            self.assertEqual(v.ce[0] >> 4, k)
            self.assertEqual(v.is_frame, k >= 6)


if __name__ == "__main__":
    unittest.main()
