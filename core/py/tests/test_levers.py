"""Levers: searches over values between reading and writing."""

import os
import re
import tomllib
import unittest

import _path  # noqa: F401
import _tools
from bassline import NotHeld, bl, decode_all, encode, first, levers, through
from bassline.cli import value_arg
from bassline.levers import LEVERS, lever
from bassline.magic import convert

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def one(search, v):
    answers = list(search(bl(v) if isinstance(v, str) else v))
    assert len(answers) == 1, answers
    return answers[0]


class KeysAsSymbols(unittest.TestCase):
    def test_every_dict_at_any_depth(self):
        self.assertEqual(one(levers.keys_as_symbols, '{"a": [{"b": 1}] 2: {"c!": x}}'),
                         bl("{2: {'c!': x} a: [{b: 1}]}"))

    def test_marks_stay(self):
        self.assertEqual(one(levers.keys_as_symbols, '!{"k"!: 1}'), bl("!{k!: 1}"))

    def test_a_collision_is_refused(self):
        with self.assertRaisesRegex(NotHeld, 'the keys "a" and a would be one key'):
            one(levers.keys_as_symbols, '{"a": 1 a: 2}')


class Numbers(unittest.TestCase):
    def test_spellings(self):
        self.assertEqual(
            one(levers.numbers, '["1815" "1.50" "-0.25" "1e3" "007" "+5" "-0" "1,000" "x" '
                                '"123456789012345678901234567890"]'),
            bl('[1815 (dec 150 -2) (dec -25 -2) (dec 1 3) "007" "+5" "-0" "1,000" "x" '
               '123456789012345678901234567890]'))

    def test_keys_stay_marks_stay(self):
        self.assertEqual(one(levers.numbers, '{"1": "2"!}'), bl('{"1": 2!}'))


class Header(unittest.TestCase):
    TABLE = '[["name" "born"] ["Ada" "1815"] ["Grace"] ["Kay" "1940" "extra"]]'

    def test_rows_as_dicts(self):
        self.assertEqual(one(levers.header, self.TABLE),
                         bl('[{"name": "Ada" "born": "1815"} {"name": "Grace"} '
                            '{"name": "Kay" "born": "1940" 2: "extra"}]'))

    def test_rows_as_records(self):
        self.assertEqual(one(lever("header=row"), '[["a"] ["1"]]'), bl('[(row {"a": "1"})]'))
        self.assertEqual(one(lever('header="my row"'), '[["a"] ["1"]]'),
                         bl('[("my row" {"a": "1"})]'))
        self.assertEqual(first(levers.header(bl('[["a"] ["1"]]'), "r")), bl('[(r {"a": "1"})]'))

    def test_a_column_named_twice(self):
        with self.assertRaisesRegex(NotHeld, "named twice"):
            one(levers.header, '[["a" "a"] ["1" "2"]]')

    def test_not_a_table_is_left_alone(self):
        for v in ('{"a": 1}', "[1 2]", "[]"):
            self.assertEqual(one(levers.header, v), bl(v))


class DropKeys(unittest.TestCase):
    def test_keys_are_values(self):
        self.assertEqual(one(levers.drop_keys(bl("1"), "a"), '{1: x "1": y a: z}'), bl('{"1": y}'))
        self.assertEqual(one(lever('drop-keys="a,b"'), '{"a,b": 1 a: 2 b: 3}'), bl("{a: 2 b: 3}"))
        self.assertEqual(one(lever("drop-keys=[a 1]"), '{1: x "a": y b: z}'), bl("{b: z}"))

    def test_text_and_symbol_keys_at_any_depth(self):
        self.assertEqual(one(levers.drop_keys("secret", "debug"),
                             '{"secret": 1 keep: {secret: 2 debug!: 3 "x": [{"debug": 4}]}}'),
                         bl('{keep: {"x": [{:}]}}'))


class TypedRecords(unittest.TestCase):
    def test_dicts_with_the_field(self):
        self.assertEqual(
            one(levers.typed_records("type"),
                '[{"type": "person" "name": "Ada" "pet": {"type": "cat" "name": "Tom"}} '
                '{"name": "untyped"} !{type: 3 x: 1}]'),
            bl('[(person {"name": "Ada" "pet": (cat {"name": "Tom"})}) {"name": "untyped"} '
               '!(3 {x: 1})]'))

    def test_two_fields_spelled_alike(self):
        with self.assertRaisesRegex(NotHeld, "both"):
            one(levers.typed_records("type"), '{"type": a type: b}')


class Entries(unittest.TestCase):
    def test_dicts_as_lists(self):
        self.assertEqual(one(levers.entries, '{b: {c: 1} a: 2}'),
                         bl("[[a 2] [b [[c 1]]]]"))


class DropWhitespace(unittest.TestCase):
    def test_indentation_between_elements(self):
        self.assertEqual(one(levers.drop_whitespace, '(a {:} "\\n  " (b {:} " x ") "\\n")'),
                         bl('(a {:} (b {:} " x "))'))
        self.assertEqual(one(levers.drop_whitespace, '[" " ""]'), bl('[" " ""]'))
        # text that is a record's only content stays: <b> </b>, <!-- -->
        self.assertEqual(one(levers.drop_whitespace, '(a {:} (b {:} " ") (comment " ") "\n")'),
                         bl('(a {:} (b {:} " ") (comment " "))'))


class Catalog(unittest.TestCase):
    def test_spellings(self):
        self.assertEqual(one(lever("drop-keys=a,b"), '{"a": 1 "b": 2 "c": 3}'), bl('{"c": 3}'))
        with self.assertRaises(LookupError):
            lever("nope")
        with self.assertRaisesRegex(ValueError, "needs an argument"):
            lever("typed-records")
        with self.assertRaisesRegex(ValueError, "takes no argument"):
            lever("numbers=1")

    def test_in_order(self):
        rows = through(levers.header, levers.numbers, levers.keys_as_symbols)
        self.assertEqual(first(rows(bl('[["n"] ["1"]]'))), bl("[{n: 1}]"))

    def test_a_lever_answering_several_readings(self):
        both = lambda v: iter((v, bl("(also)")))
        written = []
        convert(iter([bl("1"), bl("2")]), [both, levers.numbers], written.append)
        self.assertEqual(written, [bl("1"), bl("(also)"), bl("2"), bl("(also)")])

    def test_writing_stops_when_the_send_says_no(self):
        written = []
        convert(iter(bl(str(i)) for i in range(10)), [],
                lambda v: written.append(v) or len(written) < 3)
        self.assertEqual(len(written), 3)

    def test_every_lever_is_a_tool(self):
        """bin/ has a shim and pyproject a console script for each lever."""
        names = {lv.name for lv in LEVERS}
        shims = {f[len("bl-search-"):] for f in os.listdir(_tools.BIN) if f.startswith("bl-search-")}
        self.assertEqual(shims, names)
        with open(os.path.join(ROOT, "pyproject.toml"), "rb") as f:
            scripts = tomllib.load(f)["project"]["scripts"]
        for name in names:
            self.assertEqual(scripts[f"bl-search-{name}"],
                             f"bassline.levers:main_{name.replace('-', '_')}")
            fn = getattr(levers, f"main_{name.replace('-', '_')}")
            self.assertTrue(callable(fn))
        self.assertEqual(scripts["bl-magic"], "bassline.magic:main")
        for f in os.listdir(_tools.BIN):
            self.assertTrue(os.access(os.path.join(_tools.BIN, f), os.X_OK), f)


class ValueArguments(unittest.TestCase):
    def test_inline_is_text_first(self):
        self.assertEqual(value_arg("10"), bl("10"))        # not CE's text "0"
        self.assertEqual(value_arg("0"), bl("0"))
        self.assertEqual(value_arg("(row)"), bl("(row)"))
        arg = os.fsdecode(encode(bl("(a)")))           # CE bytes as a shell would hand them over
        self.assertEqual(value_arg(arg), bl("(a)"))    # not text, so CE

    def test_a_file_is_ce_first(self):
        import tempfile
        with tempfile.NamedTemporaryFile("wb", delete=False) as f:
            f.write(b"10")
        try:
            self.assertEqual(value_arg(f.name), bl('"0"'))      # the file's bytes, as CE
        finally:
            os.unlink(f.name)


class SearchTools(unittest.TestCase):
    """Each lever as bl-search-NAME, the way `bl search` runs and lists it."""

    def test_help_is_one_line_first(self):
        for lv in LEVERS:
            with self.subTest(lever=lv.name):
                r = _tools.run(f"bl-search-{lv.name}", "--help")
                self.assertEqual(r.returncode, 0)
                first_line = r.stdout.decode().splitlines()[0]
                self.assertTrue(first_line.startswith(lv.summary), first_line)
                self.assertIn(f"usage: bl search {lv.name}", r.stdout.decode())

    def test_queries(self):
        data = encode(bl('{"a": 1 "b": 2 "c": 3 "a,b": 4 5: 6}'))
        for args, left in ((["a,b"], '{5: 6 "c": 3 "a,b": 4}'), (["[a b]"], '{5: 6 "c": 3 "a,b": 4}'),
                           (['"a,b"'], '{5: 6 "a": 1 "b": 2 "c": 3}'), (["5"], '{"a": 1 "b": 2 "c": 3 "a,b": 4}')):
            r = _tools.run("bl-search-drop-keys", *args, input=data)
            self.assertEqual(decode_all(r.stdout), [bl(left)], args)
        for arg, head in (("row", "row"), ("10", "10"), ("(row)", "(row)")):
            r = _tools.run("bl-search-header", arg, input=encode(bl('[["k"] ["v"]]')))
            self.assertEqual(decode_all(r.stdout), [bl(f'[({head} {{"k": "v"}})]')], arg)

    def test_misuse(self):
        for tool, args in (("bl-search-numbers", ["x"]), ("bl-search-typed-records", []),
                           ("bl-search-numbers", ["--bogus"]), ("bl-search-numbers", ["-n", "x"])):
            with self.subTest(tool=tool, args=args):
                r = _tools.run(tool, *args)
                self.assertEqual(r.returncode, 2)
                lines = r.stderr.decode().splitlines()
                self.assertTrue(re.match(r"bl search [a-z-]+: ", lines[0]), lines[0])
                self.assertIn("usage:", r.stderr.decode())

    def test_a_refusal(self):
        r = _tools.run("bl-search-keys-as-symbols", input=encode(bl('{"a": 1 a: 2}')))
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stderr.decode(),
                         '-- keys-as-symbols: the keys "a" and a would be one key\n')


if __name__ == "__main__":
    unittest.main()
