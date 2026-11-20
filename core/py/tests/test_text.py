"""The textual syntax: the rules that trip people up, refused versus
incomplete, and a reader fed however the text arrives."""

import unittest

import _path  # noqa: F401
from gen import Gen
from bassline import (
    Bytes,
    Dict,
    Incomplete,
    Integer,
    List,
    Nil,
    ReadError,
    Reader,
    Set,
    Symbol,
    Text,
    bl,
    iter_read,
    pretty,
    read,
    read_all,
    sym,
)


def refused(text):
    """Refused as a document, so a reader that split one bad token into two
    good values couldn't pass."""
    with unittest.TestCase().assertRaises(ReadError) as caught:
        read_all(text)
    return caught.exception


def refused_one(text):
    """Refused by read, which wants exactly one value."""
    with unittest.TestCase().assertRaises(ReadError) as caught:
        read(text)
    return caught.exception


class Marks(unittest.TestCase):
    def test_go_mark_mark_frame_is_two_values(self):
        self.assertEqual(read_all("go!!(a)"), [sym.go.marked(), bl("(a)").marked()])

    def test_where_marks_go(self):
        self.assertEqual(read("[go! stop]"), List([sym.go.marked(), sym.stop]))
        self.assertEqual(read('"hi"!'), Text("hi", mark=True))
        self.assertEqual(read("0xab!"), Bytes(b"\xab", mark=True))
        self.assertEqual(read("5!"), Integer(5, mark=True))
        self.assertEqual(read("nil!"), Nil(mark=True))
        self.assertEqual(read("!{:}"), Dict(mark=True))
        self.assertEqual(read("!{}"), Set(mark=True))
        self.assertEqual(read("go!;comment"), sym.go.marked())
        self.assertEqual(read("{go!: 1}"), Dict({sym.go.marked(): 1}))

    def test_misplaced_marks(self):
        for text in ("!x", "!5", '!"a"', "(f)!", "[a]!", "!(f)!", "a!b", "5!5",
                     "! (f)", "!!(f)", "!;c\n(f)", "go!!x", "!)"):
            with self.subTest(text):
                refused(text)

    def test_a_bad_token_is_not_two_values(self):
        # read() refuses two values anyway; a document must refuse these too
        for text in ("42px", "1.5", "1-2", "1.", "a!b", "5!5", "0x1g", "go!x"):
            with self.subTest(text):
                refused(text)

    def test_waiting_marks(self):
        for text in ("!", "[!"):
            with self.subTest(text), self.assertRaises(Incomplete):
                read(text)
        # after a whole value, a mark begins a second: a document waits for
        # its frame, but the text can never be one value
        for text in ("go !", "go!!", "go! !"):
            with self.subTest(text):
                with self.assertRaises(Incomplete):
                    read_all(text)
                refused_one(text)


class Atoms(unittest.TestCase):
    def test_escapes(self):
        self.assertEqual(read(r'"a\"b"'), Text('a"b'))
        self.assertEqual(read(r"'it\'s'"), Symbol("it's"))
        self.assertEqual(read(r'"\\ \n \t \r"'), Text("\\ \n \t \r"))
        self.assertEqual(read('"raw\nnewline"'), Text("raw\nnewline"))
        for text in (r'"\'"', r"'\"'", r'"\x"', '"\\u0041"', r'"\0"'):
            with self.subTest(text):
                refused(text)

    def test_an_unknown_escape_is_refused_when_it_arrives(self):
        for text in ('"\\x', "'it\\\"", '"ok\\q and more'):
            with self.subTest(text), self.assertRaises(ReadError):
                read_all(text)
        with self.assertRaises(Incomplete):
            read('"ends in an escape \\')        # \" or \\ could still follow
        r = Reader()
        list(r.feed('"ab\\'))                    # the escape is split across chunks
        with self.assertRaises(ReadError) as caught:
            list(r.feed("x"))
        self.assertEqual(caught.exception.offset, 3)

    def test_numbers(self):
        self.assertEqual(read("1_000_000"), Integer(1000000))
        self.assertEqual(read("-1_000"), Integer(-1000))
        self.assertEqual(read("-"), sym("-"))
        self.assertEqual(read("->"), sym("->"))
        self.assertEqual(read("+5"), sym("+5"))
        self.assertEqual(read("_5"), sym("_5"))
        self.assertEqual(read("--5"), sym("--5"))
        for text in ("1_", "1__0", "1-2", "42px", "1.5", "1.", "007", "-0", "0_0",
                     "-007", "1e5", "0X12", "1\u0663"):
            with self.subTest(text):
                refused(text)

    def test_unicode_digits_are_not_numbers(self):
        self.assertEqual(read("\u0663"), sym("\u0663"))   # ARABIC-INDIC DIGIT THREE

    def test_bytes(self):
        self.assertEqual(read("0x"), Bytes(b""))
        self.assertEqual(read("0xDE_ad"), Bytes(b"\xde\xad"))
        for text in ("0x1", "0x_de", "0xde_", "0xd__e", "0xzz", "0x12g4"):
            with self.subTest(text):
                refused(text)

    def test_nil(self):
        self.assertEqual(read("nil"), Nil())
        self.assertEqual(read("'nil'"), sym("nil"))
        self.assertEqual(read("nilx"), sym("nilx"))
        self.assertEqual(str(sym("nil")), "'nil'")

    def test_colon_is_its_own_token(self):
        self.assertEqual(read("{foo:bar}"), Dict({sym.foo: sym.bar}))
        self.assertEqual(read("{1:2}"), Dict({1: 2}))
        self.assertEqual(read("'a:b'"), sym("a:b"))


class Printing(unittest.TestCase):
    def test_symbols_quoted_only_when_needed(self):
        for name, text in (("go", "go"), ("", "''"), ("nil", "'nil'"), ("5", "'5'"),
                           ("-5", "'-5'"), ("-", "-"), ("a b", "'a b'"), ("\u00e9", "\u00e9"),
                           ("x\u00a0y", "'x\u00a0y'"), ("a!b", "'a!b'"), ("it's", "'it\\'s'"),
                           ("0x", "'0x'"), ("_5", "_5"), ("a\nb", "'a\\nb'")):
            with self.subTest(name):
                self.assertEqual(str(sym(name)), text)
                self.assertEqual(read(text), sym(name))

    def test_frames(self):
        self.assertEqual(str(bl("{}")), "{}")
        self.assertEqual(str(bl("{:}")), "{:}")
        self.assertEqual(str(bl("!{:}")), "!{:}")
        self.assertEqual(str(bl("{b: 1 a: [x y]}")), "{a: [x y] b: 1}")
        self.assertEqual(str(bl("(f)")), "(f)")
        self.assertEqual(str(Text("tab\there")), '"tab\\there"')

    def test_pretty_keeps_within_width_where_it_can(self):
        v = List(range(40))
        lines = pretty(v, 20).split("\n")
        self.assertTrue(all(len(line) <= 20 for line in lines))
        self.assertEqual(read(pretty(v, 20)), v)
        self.assertEqual(pretty(bl("[1 2]"), 80), "[1 2]")


class RefusedOrIncomplete(unittest.TestCase):
    def test_incomplete(self):
        for text in ("[1 2", "(f a", "{a: 1", "{a b", "{a", "{a:", '"open', "'open",
                     '"ends in escape\\', "[1 [2] "):
            with self.subTest(text), self.assertRaises(Incomplete):
                read(text)

    def test_one_value_or_refused(self):
        # text that is all there is holds one value or is refused: no value,
        # or a second begun, however it ends, though as a document it is
        # whole or waits
        for text in ("", "   ", "; just a comment"):
            with self.subTest(text):
                self.assertEqual(read_all(text), [])
                refused_one(text)
        for text in ("1 [", '1 "open', "(f) {a", "1 ; c\n!"):
            with self.subTest(text):
                with self.assertRaises(Incomplete):
                    read_all(text)
                refused_one(text)
        self.assertEqual(read("1 ; c"), Integer(1))
        e = refused_one("1 ; c\n [")                 # refused where the second begins
        self.assertEqual((e.line, e.column, e.offset), (2, 2, 7))

    def test_refused(self):
        for text in ("[1 2)", "(]", ")", "}", ":", "{a b: c}", "{a: 1 b}", "{: a}",
                     "{a:}", "{1 1}", "{a: 1 a: 2}", "{[1] [1]}", "()", "{a: 1 : b}"):
            with self.subTest(text):
                refused(text)

    def test_text_and_symbol_are_not_duplicates(self):
        self.assertEqual(len(read("{\"a\" a}")), 2)
        with self.assertRaises(ReadError):
            read("{'a' a}")  # the same symbol, quoted or bare

    def test_where(self):
        e = refused("[1\n  )")
        self.assertEqual((e.line, e.column, e.offset), (2, 3, 5))
        e = refused_one("1 2")
        self.assertEqual(e.offset, 2)
        self.assertEqual(read_all("1 2"), [Integer(1), Integer(2)])
        e = refused("\u00e9\u00e9 )")
        self.assertEqual((e.line, e.column), (1, 4))

    def test_depth_limit(self):
        self.assertEqual(read("[[[]]]", max_depth=3), bl("[[[]]]"))
        refused_deep = None
        try:
            read("[[[]]]", max_depth=2)
        except ReadError as e:
            refused_deep = e
        self.assertIsNotNone(refused_deep)
        deep = "[" * 5000 + "]" * 5000
        v = read(deep, max_depth=5000)
        self.assertEqual(str(v), deep)


class Resumable(unittest.TestCase):
    def test_frames_land_at_their_closing_bracket(self):
        r = Reader()
        self.assertEqual(list(r.feed("(a")), [])
        self.assertEqual(list(r.feed(")")), [bl("(a)")])

    def test_atoms_land_at_the_delimiter_after_them(self):
        r = Reader()
        self.assertEqual(list(r.feed("12")), [])
        self.assertEqual(list(r.feed("3")), [])
        self.assertEqual(list(r.feed(" ")), [Integer(123)])
        self.assertEqual(list(r.feed("go!")), [])
        self.assertEqual(list(r.feed("\n")), [sym.go.marked()])
        self.assertEqual(list(r.feed('"x"')), [])
        self.assertEqual(list(r.feed("!")), [])
        self.assertEqual(list(r.feed(" ")), [Text("x", mark=True)])
        self.assertEqual(list(r.feed("last")), [])
        self.assertEqual(list(r.finish()), [sym.last])

    def test_a_mark_behind_a_frame_is_refused_when_it_arrives(self):
        r = Reader()
        self.assertEqual(list(r.feed("(f)")), [bl("(f)")])
        with self.assertRaises(ReadError):
            list(r.feed("!"))

    def test_never_refuses_a_prefix_of_good_text(self):
        for v in Gen(21).values(120):
            text = str(v)
            if len(text) > 200:
                continue
            for k in range(len(text)):
                r = Reader()
                try:
                    list(r.feed(text[:k]))
                except ReadError as e:
                    self.fail(f"refused a prefix {text[:k]!r} of {text!r}: {e}")

    def test_bytes_and_utf8(self):
        data = '"\u00e9\U0001F600" x'.encode("utf-8")
        r = Reader()
        got = []
        for i in range(len(data)):
            got.extend(r.feed(data[i:i + 1]))
        got.extend(r.finish())
        self.assertEqual(got, [Text("\u00e9\U0001F600"), sym.x])
        with self.assertRaises(ReadError):
            read(b'"\xff"')
        with self.assertRaises(Incomplete):
            read(b'"\xc3')

    def test_lone_surrogates_in_text_are_refused(self):
        with self.assertRaises(ReadError):
            read('"\ud800"')
        with self.assertRaises(ReadError):
            read("a\udc00")

    def test_once_failed_stays_failed(self):
        r = Reader()
        with self.assertRaises(ReadError) as first:
            list(r.feed(")"))
        with self.assertRaises(ReadError) as again:
            list(r.feed("(a)"))
        self.assertIs(again.exception, first.exception)

    def test_iter_read(self):
        self.assertEqual(list(iter_read(["(a", ") 1", "2 [", "]"])),
                         [bl("(a)"), Integer(12), List()])


if __name__ == "__main__":
    unittest.main()
