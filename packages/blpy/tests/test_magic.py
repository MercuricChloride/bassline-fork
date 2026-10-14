"""bl-magic end to end, through the bin/ shims, as a shell would run it."""

import json as stdjson
import os
import subprocess
import sys
import tempfile
import unittest

import _path  # noqa: F401
import _tools
from test_doors import HAS_YAML, SAMPLES, THIRTY
from bassline import bl, decode_all, doors, encode, encode_all, levers, read_all

_SRC = os.path.join(os.path.dirname(_tools.BIN), "src")
JSON_DOC = (f'{{"name": "Ada", "price": 1.50, "big": {THIRTY}, '
            '"ok": true, "tags": ["x", null]}\n').encode()
CSV_DOC = b"name,born,price,zip\nAda,1815,1.50,007\nGrace,1906,,02134\n"


def lines(err: bytes) -> list[str]:
    return err.decode().splitlines()


class Magic(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def path(self, name: str, data: bytes | None = None) -> str:
        p = os.path.join(self.dir.name, name)
        if data is not None:
            with open(p, "wb") as f:
                f.write(data)
        return p

    def magic(self, *args, input=b""):
        return _tools.run("bl-magic", *args, input=input, cwd=self.dir.name)

    # -- the conversions in cli.md

    def test_json_file_to_ce_to_text(self):
        self.path("data.json", JSON_DOC)
        ce = self.magic("data.json")
        self.assertEqual(ce.returncode, 0)
        self.assertEqual(lines(ce.stderr), ["-- reading data.json as json (from its extension)"])
        [v] = decode_all(ce.stdout)
        self.assertEqual(v, bl(f'{{"name": "Ada" "price": (dec 150 -2) "big": {THIRTY} '
                               '"ok": true "tags": ["x" nil]}'))
        text = self.magic("-t", "text", input=ce.stdout)
        self.assertEqual(text.returncode, 0)
        self.assertEqual(lines(text.stderr), ["-- reading stdin as ce (guessed from content)"])
        self.assertEqual(read_all(text.stdout.decode()), [v])
        self.assertIn("(dec 150 -2)", text.stdout.decode())

    def test_csv_with_levers_to_json(self):
        self.path("people.csv", CSV_DOC)
        r = self.magic("people.csv", "out.json", "-l", "header", "-l", "numbers")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(lines(r.stderr), ["-- reading people.csv as csv (from its extension)",
                                           "-- writing out.json as json (from its extension)"])
        with open(self.path("out.json"), encoding="utf-8") as f:
            text = f.read()
        self.assertEqual(stdjson.loads(text), [
            {"name": "Ada", "born": 1815, "price": 1.5, "zip": "007"},
            {"name": "Grace", "born": 1906, "price": "", "zip": "02134"}])
        self.assertIn('"price": 1.50', text)        # spelled as the CSV spelled it

    def test_readings(self):
        r = self.magic("--readings", "-t", "text", input=b'{"a": 1}')
        self.assertEqual(r.returncode, 0, r.stderr)
        found = read_all(r.stdout.decode())
        self.assertEqual(found[0], bl('(reading json {"a": 1})'))
        self.assertIn(bl('(reading json-entries (object ["a" 1]))'), found)
        self.assertIn(bl('(reading text {"a": 1})'), found)
        self.assertEqual(r.stderr, b"")
        # in CE by default, levers applied to each reading
        r = self.magic("--readings", "-l", "keys-as-symbols", input=b'{"a": 1}')
        self.assertEqual(decode_all(r.stdout)[0], bl("(reading json {a: 1})"))
        # one door's readings with -f; nothing plausible is a failure
        r = self.magic("--readings", "-f", "json", "-t", "text", input=b'{"a": 1, "a": 2}')
        self.assertEqual(read_all(r.stdout.decode()),
                         [bl('(reading json-entries (object ["a" 1] ["a" 2]))')])
        r = self.magic("--readings", "-f", "csv", "-t", "text", input=b"a\nb\n")
        self.assertEqual(r.stdout, b'(reading csv [["a"] ["b"]])\n')   # -f taken at its word
        r = self.magic("--readings", input=b"plain words, nothing more")
        self.assertEqual((r.returncode, r.stdout), (1, b""))
        self.assertEqual(lines(r.stderr), ["-- stdin: no plausible reading"])

    def test_formats_and_levers(self):
        r = self.magic("--formats")
        self.assertEqual(r.returncode, 0)
        listed = [line.split()[0] for line in r.stdout.decode().splitlines()]
        self.assertEqual(listed, [d.name for d in doors.KNOWN])
        if not HAS_YAML:
            self.assertIn("needs PyYAML", r.stdout.decode())
        r = self.magic("--levers")
        self.assertEqual([line.split()[0] for line in r.stdout.decode().splitlines()],
                         [lv.spelling for lv in levers.LEVERS])

    def test_a_lever_as_a_ce_filter(self):
        values = [bl('{"a": [{"b": 1}]}'), bl('(x {"c": 2})')]
        r = self.magic("-l", "keys-as-symbols", input=encode_all(values))
        self.assertEqual(r.returncode, 0)
        self.assertEqual(decode_all(r.stdout), [bl("{a: [{b: 1}]}"), bl("(x {c: 2})")])
        self.assertEqual(lines(r.stderr), ["-- reading stdin as ce (guessed from content)"])

    def test_empty_input(self):
        self.path("empty.json", b"")
        for args in ((), ("empty.json", "out.toml"), ("--readings",), ("-f", "csv")):
            with self.subTest(args=args):
                r = self.magic(*args)
                self.assertEqual((r.returncode, r.stdout), (0, b""))
        self.assertFalse(os.path.exists(self.path("out.toml")))

    # -- choosing formats, and saying so

    def test_flags_override_extensions(self):
        self.path("data.csv", JSON_DOC)
        r = self.magic("data.csv", "out.json", "-f", "json", "-t", "text")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, b"")              # nothing guessed, nothing said
        with open(self.path("out.json"), encoding="utf-8") as f:
            self.assertIn("(dec 150 -2)", f.read())
        r = self.magic("data.csv", "-f", "jsonl", "-t", "jsonl")
        self.assertEqual(r.stdout.decode().count("\n"), 1)

    def test_guessing_from_content(self):
        for name, data in SAMPLES.items():
            if name == "yaml" and not HAS_YAML:
                continue
            with self.subTest(format=name):
                r = self.magic(input=data)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(lines(r.stderr)[0],
                                 f"-- reading stdin as {name} (guessed from content)")
                self.assertEqual(decode_all(r.stdout), list(doors.named(name).read(data)))

    def test_guessing_a_file_with_no_known_extension(self):
        self.path("notes.txt", CSV_DOC)
        r = self.magic("notes.txt", "-t", "text")
        self.assertEqual(lines(r.stderr), ["-- reading notes.txt as csv (guessed from content)"])
        self.path("values.dat", encode_all([bl("(a)"), bl("[b]")]))
        r = self.magic("values.dat", "out.bin")
        self.assertEqual(lines(r.stderr), ["-- reading values.dat as ce (guessed from content)",
                                           "-- writing out.bin as ce (no format known for its extension)"])

    def test_cant_tell(self):
        r = self.magic(input=b"just a few words, nothing more\n")
        self.assertEqual((r.returncode, r.stdout), (1, b""))
        self.assertTrue(lines(r.stderr)[0].startswith("-- can't tell what format stdin is; say it with -f"))

    def test_output_by_extension(self):
        self.path("two.blb", encode_all([bl('{"a": 1}'), bl("[2]")]))
        for out, want in (("out.jsonl", '{"a": 1}\n[2]\n'), ("out.bl", '{"a": 1}\n[2]\n')):
            r = self.magic("two.blb", out)
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(self.path(out), encoding="utf-8") as f:
                self.assertEqual(f.read(), want)

    # -- what goes wrong

    def test_misuse(self):
        for args in (("--bogus",), ("-f", "docx"), ("-t", "json-entries"), ("-l", "nope"),
                     ("-l", "drop-keys"), ("a", "b", "c")):
            with self.subTest(args=args):
                r = self.magic(*args)
                self.assertEqual(r.returncode, 2)
                self.assertTrue(lines(r.stderr)[0].startswith("bl magic: "), r.stderr)
                self.assertIn(b"usage: bl magic", r.stderr)
                self.assertEqual(r.stdout, b"")
        r = self.magic("-h")
        self.assertEqual(r.returncode, 0)
        self.assertTrue(r.stdout.startswith(b"convert between formats"))

    def test_long_option_spellings(self):
        for args in (("--to", "text"), ("--to=text",), ("--to:text",)):
            r = self.magic(*args, input=encode(bl("[1]")))
            self.assertEqual(r.stdout, b"[1]\n", args)

    def test_failures(self):
        r = self.magic("nope.json")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(lines(r.stderr)[-1], "-- can't read nope.json: No such file or directory")
        self.path("data.json", JSON_DOC)
        r = self.magic("data.json", "out.toml")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(lines(r.stderr)[-1], f"-- out.toml: can't write that as toml: TOML's "
                                              f"integers are 64-bit, and {THIRTY} isn't")
        self.assertFalse(os.path.exists(self.path("out.toml")))
        self.path("bad.json", b'{"a": NaN}')
        r = self.magic("bad.json")
        self.assertEqual(lines(r.stderr)[-1], "-- bad.json: NaN is not JSON, and no number holds it")
        r = self.magic("data.json", "data.json", "-t", "json")
        self.assertEqual(r.returncode, 2)
        os.mkdir(self.path("adir"))
        r = self.magic("adir")
        self.assertEqual((r.returncode, lines(r.stderr)), (1, ["-- can't read adir: Is a directory"]))
        r = self.magic("data.json", "adir/no/such/out.json")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(lines(r.stderr)[-1],
                         "-- can't write adir/no/such/out.json: No such file or directory")

    def test_a_reading_that_refuses_falls_to_the_next(self):
        self.path("dup.json", b'{"a": 1, "a": 2}')
        r = self.magic("dup.json", "-t", "text")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, b'(object ["a" 1] ["a" 2])\n')
        self.assertRegex(lines(r.stderr)[-1],
                         r'^-- dup.json: the json reading refused it \(.*twice.*\); read as json-entries$')

    def test_more_conversions(self):
        self.path("doc.xml", b"<doc>\n  <p id=\"1\">hi</p>\n  <p/>\n</doc>\n")
        r = self.magic("doc.xml", "-l", "drop-whitespace", "-t", "text")
        self.assertEqual(read_all(r.stdout.decode()),
                         [bl('(doc {:} (p {"id": "1"} "hi") (p {:}))')])
        self.path("c.toml", b"day = 1979-05-27\nprice = 1.50\n")
        r = self.magic("c.toml", "-t", "jsonl")
        self.assertEqual(r.stdout, b'{"day": "1979-05-27", "price": 1.50}\n')
        r = self.magic("c.toml", "-l", "keys-as-symbols", "-l", "entries", "-t", "text")
        self.assertEqual(r.stdout, b"[[day (date 1979 5 27)] [price (dec 150 -2)]]\n")

    def test_a_lever_from_path(self):
        """A lever this magic doesn't have runs as bl-search-NAME from PATH,
        whatever implements it, as a stage between reading and writing."""
        tool = self.path("bl-search-shout", (
            "#!" + sys.executable + "\n"
            "import sys\n"
            f"sys.path.insert(0, {_SRC!r})\n"
            "from bassline import read_ce, ce_writer, rec, sym, Text\n"
            "out = ce_writer(1)\n"
            "for v in read_ce(0):\n"
            "    out(rec(sym.shouted, Text(sys.argv[1] if len(sys.argv) > 1 else ''), v))\n").encode())
        os.chmod(tool, 0o755)
        env = dict(os.environ, PATH=self.dir.name + os.pathsep + os.environ.get("PATH", ""))
        run = lambda *args, input=b"": subprocess.run(_tools.argv("bl-magic", *args), input=input,
                                                      capture_output=True, env=env, timeout=60)
        r = run("-l", "keys-as-symbols", "-l", "shout=loud", "-l", "numbers", "-t", "text",
                input=b'{"a": "1"}\n{"b": "2"}')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read_all(r.stdout.decode()),
                         [bl('(shouted "loud" {a: 1})'), bl('(shouted "loud" {b: 2})')])
        r = run("--levers")
        self.assertIn("shout[=ARG]", r.stdout.decode())

    def test_the_shims_run_from_path(self):
        env = dict(os.environ, PATH=_tools.BIN + os.pathsep + os.environ.get("PATH", ""))
        r = subprocess.run(["bl-magic", "-t", "text"], input=b'["x"]', capture_output=True,
                           env=env, timeout=60)
        self.assertEqual(r.stdout, b'["x"]\n')
        r = subprocess.run(["bl-search-numbers"], input=encode(bl('"12"')), capture_output=True,
                           env=env, timeout=60)
        self.assertEqual(r.stdout, encode(bl("12")))


if __name__ == "__main__":
    unittest.main()
