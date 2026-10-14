"""Format doors: first passes, refusals, writers, round trips and guessing."""

import json as stdjson
import os
import tomllib
import unittest

import _path  # noqa: F401
from gen import Gen
from bassline import (
    Bytes,
    Dict,
    Integer,
    List,
    NotHeld,
    Set,
    Text,
    bl,
    doors,
    encode_all,
    rec,
    sym,
)
from bassline.doors import _vocab

CORPUS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "corpus")
HAS_YAML = doors.yaml.door.available
J = doors.json

THIRTY = "123456789012345678901234567890"


def json_holdable(v):
    """Whether ``v`` survives the JSON door both ways: nil, integers, text,
    true/false, lists and text-keyed dicts, and no marks."""
    if v.mark:
        return False
    k = v.kind.name
    if k in ("NIL", "INTEGER", "TEXT"):
        return True
    if k == "SYMBOL":
        return v.name in ("true", "false")
    if k == "LIST":
        return all(json_holdable(m) for m in v)
    if k == "DICT":
        return all(key.kind.name == "TEXT" and not key.mark and json_holdable(x)
                   for key, x in v.items())
    return False


class JSONReading(unittest.TestCase):
    def test_first_pass(self):
        v = J.loads('{"s": "x", "n": null, "t": true, "f": false, "a": [1, [], {}]}')
        self.assertEqual(v, bl('{"s": "x" "n": nil "t": true "f": false "a": [1 [] {:}]}'))

    def test_numbers_from_their_spelling(self):
        v = J.loads(f'[{THIRTY}, -{THIRTY}, 1.50, 0.1, 1E+2, 1e-40, -0.25, 0, 5e0]')
        self.assertEqual(v, bl(f"[{THIRTY} -{THIRTY} (dec 150 -2) (dec 1 -1) (dec 1 2) "
                               "(dec 1 -40) (dec -25 -2) 0 (dec 5 0)]"))
        self.assertEqual(J.loads("1" * 5000), Integer(int("1" * 4000) * 10**1000
                                                       + int("1" * 1000)))

    def test_negative_zero_keeps_its_spelling(self):
        self.assertEqual(J.loads("[-0, -0.0, -0e3]"),
                         bl('[(number "-0") (number "-0.0") (number "-0e3")]'))
        self.assertEqual(J.dumps(J.loads("[-0, -0.0]"), "jsonl"), "[-0, -0.0]\n")

    def test_refusals(self):
        for doc in ("NaN", "[Infinity]", "[-Infinity]", '"\\ud800"', '{"\\udc00": 1}',
                    "01", "[1][2]", "[1,]", "{'a': 1}", "", "  "):
            with self.subTest(doc=doc):
                with self.assertRaises(NotHeld):
                    J.loads(doc)

    def test_duplicate_keys(self):
        doc = '{"b": 1, "a": 2, "b": 3}'
        with self.assertRaisesRegex(NotHeld, "appears twice"):
            J.loads(doc)
        entries = J.loads(doc, "json-entries")
        self.assertEqual(entries, bl('(object ["b" 1] ["a" 2] ["b" 3])'))
        # and the writer gives the object back, order and repeats kept
        self.assertEqual(J.dumps(entries, "jsonl"), '{"b": 1, "a": 2, "b": 3}\n')

    def test_several_texts(self):
        self.assertEqual(list(J.read('{"a": 1}\n[2]\n"three"\n')),
                         [bl('{"a": 1}'), bl("[2]"), bl('"three"')])

    def test_encoding(self):
        self.assertEqual(J.loads(b'\xef\xbb\xbf{"a": "\xc3\xa9"}'), Dict({"a": "\u00e9"}))
        with self.assertRaisesRegex(NotHeld, "UTF-8"):
            J.loads(b'"\xff"')


class JSONWriting(unittest.TestCase):
    def test_round_trips(self):
        for v in Gen(7).values(300):
            if json_holdable(v):
                with self.subTest(v=str(v)[:60]):
                    for w in ("json", "jsonl"):
                        self.assertEqual(J.loads(J.dumps(v, w)), v)

    def test_exact_numbers_out(self):
        v = bl(f'{{"big": {THIRTY} "price": (dec 150 -2) "tiny": (dec 1 -40) "k": (dec 15 0)}}')
        text = J.dumps(v, "jsonl")
        self.assertIn(f'"big": {THIRTY}', text)
        self.assertIn('"price": 1.50', text)
        self.assertEqual(J.loads(text), v)

    def test_lossy_but_sensible(self):
        v = bl('[go! {sym: 0xff} {1 2} (point 1 2) (date 2026 10 2) '
               '(datetime (date 1979 5 27) (time 0 32 (dec 5 -1)) (offset -420)) {3: x}]')
        self.assertEqual(stdjson.loads(J.dumps(v)),
                         ["go", {"sym": "0xff"}, [1, 2], ["point", 1, 2], "2026-10-02",
                          "1979-05-27T00:32:00.5-07:00", {"3": "x"}])

    def test_keys_spelled_alike_are_refused(self):
        for v in ('{1: a "1": b}', '{a: 1 "a": 2}'):
            with self.assertRaisesRegex(NotHeld, "both"):
                J.dumps(bl(v))

    def test_indented_by_default(self):
        self.assertEqual(J.dumps(bl('{"a": [1 2]}')), '{\n  "a": [\n    1,\n    2\n  ]\n}\n')
        self.assertEqual(J.dumps(bl("[]")), "[]\n")


class CSVDoor(unittest.TestCase):
    def test_rows_of_text(self):
        doc = 'name,born\r\nAda,1815\n"Hopper, Grace","1906"\n"say ""hi""",\n\n"two\nlines",x\n'
        self.assertEqual(doors.csv.loads(doc),
                         bl('[["name" "born"] ["Ada" "1815"] ["Hopper, Grace" "1906"] '
                            '["say \\"hi\\"" ""] [] ["two\\nlines" "x"]]'))

    def test_nothing_guessed(self):
        self.assertEqual(doors.csv.loads("007,1.50,true,\n"),
                         bl('[["007" "1.50" "true" ""]]'))

    def test_a_quote_out_of_place_is_refused(self):
        for doc in ('"ab"c,d\n', 'a,"unterminated\n'):
            with self.subTest(doc=doc):
                with self.assertRaisesRegex(NotHeld, "not CSV"):
                    doors.csv.loads(doc)

    def test_round_trip(self):
        table = bl('[["a" "b,c"] ["say \\"x\\"" "two\\nlines"] ["" "x"]]')
        self.assertEqual(doors.csv.loads(doors.csv.dumps(table)), table)

    def test_writer(self):
        table = bl('[{name: "Ada" born: 1815} {name: "Grace" price: (dec 150 -2) note: nil}]')
        self.assertEqual(doors.csv.dumps(table),
                         "born,name,note,price\n1815,Ada,,\n,Grace,,1.50\n")
        with self.assertRaisesRegex(NotHeld, "a table"):
            doors.csv.dumps(bl("42"))
        with self.assertRaisesRegex(NotHeld, "header can't hold"):
            doors.csv.dumps(bl('[{a: 1 "a": 2}]'))
        self.assertEqual(doors.csv.dumps(bl('[1 "x" go]')), "1,x,go\n")   # one row

    def test_dict_rows_one_at_a_time_share_a_header(self):
        import io
        buf = io.BytesIO()
        send = doors.csv.writer(buf)
        send(bl('{a: 1 b: 2}'))
        send(bl('{b: 3}'))
        self.assertEqual(buf.getvalue(), b"a,b\n1,2\n,3\n")
        with self.assertRaisesRegex(NotHeld, "header"):
            send(bl('{c: 4}'))

    def test_tsv(self):
        self.assertEqual(doors.tsv.loads('a"b\t"c"\n1\t\n'), bl('[["a\\"b" "\\"c\\""] ["1" ""]]'))
        table = bl('[["q\\"uote" "x"]]')
        self.assertEqual(doors.tsv.loads(doors.tsv.dumps(table)), table)
        with self.assertRaisesRegex(NotHeld, "TSV can't hold"):
            doors.tsv.dumps(bl('[["a\\tb"]]'))


TOML_DOC = '''
title = "doc"
price = 1.50
n = 1_000
f = +1.5
big = 9_223_372_036_854_775_807
hex = 0xdead
plus_inf = +inf
nan = nan
neg_zero = -0.0
when = 1979-05-27T00:32:00.5-07:00
utc = 1979-05-27T07:32:00Z
local = 1979-05-27T07:32:00
day = 1979-05-27
alarm = 07:32:00.25
flags = [true, false]
mixed = [1, "two", { three = 3 }]

[owner]
name = "Tom"

[owner.address]
"street name" = "Main"
'''


class TOMLDoor(unittest.TestCase):
    def test_first_pass(self):
        v = doors.toml.loads(TOML_DOC)
        want = {
            "title": bl('"doc"'), "price": bl("(dec 150 -2)"), "n": bl("1000"),
            "f": bl("(dec 15 -1)"), "big": bl("9223372036854775807"), "hex": bl("57005"),
            "plus_inf": bl('(number "+inf")'), "nan": bl('(number "nan")'),
            "neg_zero": bl('(number "-0.0")'),
            "when": bl("(datetime (date 1979 5 27) (time 0 32 (dec 5 -1)) (offset -420))"),
            "utc": bl("(datetime (date 1979 5 27) (time 7 32 0) (offset 0))"),
            "local": bl("(datetime (date 1979 5 27) (time 7 32 0))"),
            "day": bl("(date 1979 5 27)"), "alarm": bl("(time 7 32 (dec 25 -2))"),
            "flags": bl("[true false]"), "mixed": bl('[1 "two" {"three": 3}]'),
            "owner": bl('{"name": "Tom" "address": {"street name": "Main"}}'),
        }
        for k, x in want.items():
            with self.subTest(key=k):
                self.assertEqual(v[k], x)
        self.assertEqual(len(v), len(want))

    def test_fractions_of_a_second_as_written(self):
        v = doors.toml.loads('a = 07:32:00.500\nb = 1979-05-27T00:32:00.999999999Z\n'
                             's = "12:00:00.1234567" # 13:00:00.5\nm = """\n11:11:11.25"""\n')
        self.assertEqual(v, bl('{"a": (time 7 32 (dec 500 -3)) '
                               '"b": (datetime (date 1979 5 27) (time 0 32 (dec 999999999 -9)) (offset 0)) '
                               '"s": "12:00:00.1234567" "m": "11:11:11.25"}'))
        self.assertIn("07:32:00.500", doors.toml.dumps(v))
        with self.assertRaisesRegex(NotHeld, "which is which"):
            doors.toml.loads("a = 07:32:00.5\nb = 07:32:00.50\n")

    def test_round_trip(self):
        v = doors.toml.loads(TOML_DOC)
        text = doors.toml.dumps(v)
        self.assertEqual(doors.toml.loads(text), v)
        tomllib.loads(text)        # and it is TOML to the standard library

    def test_refusals(self):
        with self.assertRaisesRegex(NotHeld, "not TOML"):
            doors.toml.loads("a = ")
        with self.assertRaisesRegex(NotHeld, "not TOML"):
            doors.toml.loads("a = 1\na = 2\n")
        for v, why in ((bl("[1 2]"), "a table"), (bl('{"a": nil}'), "no nil"),
                       (bl(f'{{"a": {THIRTY}}}'), "64-bit"), (bl('{1: a "1": b}'), "both")):
            with self.subTest(v=str(v)):
                with self.assertRaisesRegex(NotHeld, why):
                    doors.toml.dumps(v)

    def test_one_document(self):
        import io
        send = doors.toml.writer(io.BytesIO())
        send(bl('{"a": 1}'))
        with self.assertRaisesRegex(NotHeld, "one table"):
            send(bl('{"b": 2}'))

    def test_lossy_writing(self):
        v = bl('{a: go "b c": 0xff s: {1 2} r: (point 1 2) t: (time 7 0 0 (offset 60))}')
        self.assertEqual(tomllib.loads(doors.toml.dumps(v)),
                         {"a": "go", "b c": "0xff", "s": [1, 2], "r": ["point", 1, 2],
                          "t": "07:00:00+01:00"})


XML_DOC = b'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE note SYSTEM "note.dtd">
<!-- before -->
<note xmlns:x="urn:x" id="7" x:lang="en">
  <to>Tove &amp; co</to>
  <x:body><![CDATA[<b>hi</b>]]> and <em>more</em></x:body>
  <empty/>
  <?render fast?>
</note>
'''


class XMLDoor(unittest.TestCase):
    def test_shape(self):
        nodes = list(doors.xml.read(XML_DOC))
        self.assertEqual(nodes[0], bl('(doctype note {system: "note.dtd"})'))
        self.assertEqual(nodes[1], bl('(comment " before ")'))
        note = nodes[2]
        self.assertEqual(note.head, sym.note)
        self.assertEqual(note[1], bl('{"id": "7" "x:lang": "en" "xmlns:x": "urn:x"}'))
        children = [c for c in note.fields[1:] if not (c.kind.name == "TEXT" and not c.value.strip())]
        self.assertEqual(children, [
            bl('(to {:} "Tove & co")'),
            bl('(\'x:body\' {:} "<b>hi</b> and " (em {:} "more"))'),
            bl("(empty {:})"),
            bl('(pi render "fast")'),
        ])
        self.assertEqual(len(nodes), 3)

    def test_a_run_of_text_is_one_text(self):
        v = doors.xml.loads("<a>" + "x&amp;" * 10000 + "<b/>" + "y\n" * 5000 + "</a>")
        self.assertEqual([len(f.value) if f.kind.name == "TEXT" else f.head.name
                          for f in v.fields[1:]], [20000, "b", 10000])

    def test_entities_and_the_internal_subset(self):
        doc = b"""<!DOCTYPE n [
<!ENTITY ext SYSTEM "x.txt">
<!ENTITY in "inner">
<!ENTITY % p "pp">
<!ATTLIST n lang CDATA "en" id ID #REQUIRED>
<!ELEMENT n (#PCDATA|b)*>
<!NOTATION gif SYSTEM "image/gif">
]><n id="i">a&ext;b&in;c</n>"""
        nodes = list(doors.xml.read(doc))
        self.assertEqual(nodes[0], bl('(doctype n {:} (ENTITY ext {system: "x.txt"}) (ENTITY in "inner") '
                                      '(ENTITY % p "pp") (ATTLIST n lang "CDATA" "en") '
                                      '(ATTLIST n id "ID" "#REQUIRED") (ELEMENT n "(#PCDATA|b)*") '
                                      '(NOTATION gif {system: "image/gif"}))'))
        # the default lang isn't added: only what the element wrote
        self.assertEqual(nodes[1], bl('(n {"id": "i"} "a" (entity ext) "binnerc")'))
        text = "".join(doors.xml.dumps(n) for n in nodes)
        self.assertEqual(list(doors.xml.read(text)), nodes)
        xhtml = (b'<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" '
                 b'"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd"><p>a&nbsp;b</p>')
        self.assertEqual(list(doors.xml.read(xhtml))[1], bl('(p {:} "a" (entity nbsp) "b")'))

    def test_round_trip(self):
        nodes = list(doors.xml.read(XML_DOC))
        text = "".join(doors.xml.dumps(n) for n in nodes)
        self.assertEqual(list(doors.xml.read(text)), nodes)

    def test_refusals(self):
        for doc in ("<a><b></a>", "<a>&nbsp;</a>", "<a/><b/>", "not xml"):
            with self.subTest(doc=doc):
                with self.assertRaisesRegex(NotHeld, "not XML"):
                    list(doors.xml.read(doc))
        with self.assertRaisesRegex(NotHeld, "elements"):
            doors.xml.dumps(bl('{"a": 1}'))
        with self.assertRaisesRegex(NotHeld, "element name"):
            doors.xml.dumps(bl('("not a name" {:})'))
        with self.assertRaisesRegex(NotHeld, "both"):
            doors.xml.dumps(bl('(a {a: 1 "a": 2})'))

    def test_writing_records_a_lever_made(self):
        self.assertEqual(doors.xml.dumps(bl('(person {name: "Ada & co" born: 1815} "text" 42)')),
                         '<person born="1815" name="Ada &amp; co">text42</person>\n')


class OtherDoors(unittest.TestCase):
    def test_ce(self):
        values = Gen(11).values(100)
        data = encode_all(values)
        self.assertEqual(list(doors.ce.read(data)), values)
        self.assertEqual(doors.ce.dumps(values[0]), values[0].ce)

    def test_text(self):
        values = Gen(12).values(100)
        doc = "".join(doors.text.dumps(v) for v in values)
        self.assertEqual(list(doors.text.read(doc)), values)

    def test_carrier(self):
        values = Gen(13).values(100)
        doc = "".join(doors.carrier.dumps(v) for v in values)
        self.assertEqual(list(doors.carrier.read(doc)), values)
        with open(os.path.join(CORPUS, "corpus.json"), "rb") as f:
            corpus = list(doors.carrier.read(f.read()))
        with open(os.path.join(CORPUS, "corpus.blb"), "rb") as f:
            self.assertEqual(corpus, list(doors.ce.read(f.read())))


@unittest.skipUnless(HAS_YAML, "PyYAML isn't installed")
class YAMLDoor(unittest.TestCase):
    DOC = """
base: &base {color: red, size: 2}
price: 1.50
half: .5
big: 123456789012345678901234567890
inf: -.inf
yes_: yes
day: !!timestamp 2002-12-14
when: !!timestamp 2001-12-14t21:59:43.10-05:00
blob: !!binary aGk=
tags: !!set {a, b}
point: !point [1, 2]
label: !label red
copy: *base
nothing: ~
"""

    def test_first_pass(self):
        v = doors.yaml.loads(self.DOC)
        self.assertEqual(v[Text("price")], bl("(dec 150 -2)"))
        self.assertEqual(v[Text("half")], bl("(dec 5 -1)"))
        self.assertEqual(v[Text("big")], bl(THIRTY))
        self.assertEqual(v[Text("inf")], bl('(number "-.inf")'))
        self.assertEqual(v[Text("yes_")], bl('"yes"'))
        self.assertEqual(v[Text("day")], bl("(date 2002 12 14)"))
        self.assertEqual(v[Text("when")],
                         bl("(datetime (date 2001 12 14) (time 21 59 (dec 4310 -2)) (offset -300))"))
        self.assertEqual(v[Text("blob")], Bytes(b"hi"))
        self.assertEqual(v[Text("tags")], Set(["a", "b"]))
        self.assertEqual(v[Text("point")], bl("(point 1 2)"))
        self.assertEqual(v[Text("label")], bl('(label "red")'))
        self.assertEqual(v[Text("copy")], v[Text("base")])
        self.assertEqual(v[Text("nothing")], bl("nil"))

    def test_what_yaml_1_1_and_1_2_read_differently_stays_text(self):
        v = doors.yaml.loads("country: no\non: yes\nmode: 010\nduration: 1:30\n"
                             "big: 1_000\nexp: 1e3\nday: 2002-12-14\nok: true\nn: -0\n"
                             "hex: 0x1F\nf: !!float 1\ntiny: 43.123456789\n")
        self.assertEqual(v, bl('{"country": "no" "on": "yes" "mode": "010" "duration": "1:30" '
                               '"big": "1_000" "exp": "1e3" "day": "2002-12-14" "ok": true '
                               '"n": (number "-0") "hex": 31 "f": (dec 1 0) '
                               '"tiny": (dec 43123456789 -9)}'))

    def test_tags_taken_at_their_word(self):
        v = doors.yaml.loads("[!!timestamp '2001-12-14 21:59:43.100', !!foo a, !foo a, "
                             "!!bool yes, !!int 0x10]")
        self.assertEqual(v, bl("[(datetime (date 2001 12 14) (time 21 59 (dec 43100 -3))) "
                               "('!!foo' \"a\") (foo \"a\") true 16]"))
        for doc in ("!!int abc", "!!bool maybe", "!!timestamp abc", "!!binary '!!!'",
                    "!!float abc", "!!null x", "!!set {a: 1}", "!!timestamp 2001-02-30"):
            with self.subTest(doc=doc):
                with self.assertRaises(NotHeld):
                    doors.yaml.loads(doc)

    def test_written_so_either_version_reads_it(self):
        import yaml as pyyaml
        v = bl('["no" "010" "2002-12-14" "1e3" "on" (dec 1 3) (date 2026 10 2)]')
        text = doors.yaml.dumps(v)
        self.assertEqual(doors.yaml.loads(text), v)
        self.assertEqual(pyyaml.safe_load(text)[:5], ["no", "010", "2002-12-14", "1e3", "on"])
        with self.assertRaisesRegex(NotHeld, "both"):
            doors.yaml.dumps(bl('{a: 1 "a": 2}'))

    def test_refusals(self):
        with self.assertRaisesRegex(NotHeld, "twice"):
            doors.yaml.loads("a: 1\na: 2\n")
        with self.assertRaisesRegex(NotHeld, "contains itself"):
            doors.yaml.loads("&a [*a]")
        with self.assertRaisesRegex(NotHeld, "not YAML"):
            doors.yaml.loads("a: [1\n")

    def test_round_trip(self):
        v = doors.yaml.loads(self.DOC)
        self.assertEqual(doors.yaml.loads(doors.yaml.dumps(v)), v)
        for w in Gen(14).values(200):
            if json_holdable(w):
                self.assertEqual(doors.yaml.loads(doors.yaml.dumps(w)), w)
        odd = bl('[(dec 1 3) "123" "true" "" (point 1 [2]) {1 2} (date 2026 10 2)]')
        self.assertEqual(doors.yaml.loads(doors.yaml.dumps(odd)), odd)

    def test_several_documents(self):
        self.assertEqual(list(doors.yaml.read("--- 1\n--- [2]\n")), [bl("1"), bl("[2]")])


class Vocabulary(unittest.TestCase):
    def test_number_spellings(self):
        cases = {"0": "0", "-7": "-7", "1.50": "(dec 150 -2)", "1e3": "(dec 1 3)",
                 "1.5E-3": "(dec 15 -4)", "0.001": "(dec 1 -3)", "-0": '(number "-0")'}
        for s, want in cases.items():
            self.assertEqual(_vocab.number(s), bl(want))
        for s in ("007", "+5", "1.", ".5", "1e", "", "1_000", "0x10"):
            self.assertIsNone(_vocab.number(s), s)
        self.assertEqual(_vocab.number("1.", lenient=True), bl("(dec 1 0)"))
        self.assertEqual(_vocab.number("+.5", lenient=True), bl("(dec 5 -1)"))

    def test_dec_spellings_read_back(self):
        for m in (0, 1, -1, 150, -25, 10**40):
            for e in (-50, -12, -3, -1, 0, 1, 7):
                s = _vocab.dec_spelling(Integer(m), e)
                self.assertEqual(_vocab.number(s), _vocab.dec(m, e), s)


SAMPLES = {
    "json": b'{"name": "Ada", "tags": ["x", "y"]}\n',
    "carrier": b'{"kind": "list", "value": [{"kind": "number", "value": 1}]}',
    "csv": b"name,born\nAda,1815\nGrace,1906\n",
    "tsv": b"name\tborn\nAda\t1815\nGrace\t1906\n",
    "toml": b'title = "x"\n[owner]\nname = "Tom"\n',
    "xml": b'<?xml version="1.0"?>\n<a href="x"><b/></a>\n',
    "text": b"(person {name: \"Ada\"}) [1 2 3]\n; a comment\n",
    "ce": encode_all([bl("(person {name: \"Ada\"})"), bl("[1 2]")]),
    "yaml": b"name: Ada\ntags:\n  - x\n  - y\n",
}


class Guessing(unittest.TestCase):
    def test_each_format_is_its_own_best_guess(self):
        for name, data in SAMPLES.items():
            if name == "yaml" and not HAS_YAML:
                continue
            with self.subTest(format=name):
                ranked = doors.guess(data)
                self.assertEqual(ranked[0][1].name, name, ranked)
                self.assertGreaterEqual(ranked[0][0], doors.PLAUSIBLE)

    def test_the_corpus_files(self):
        for file, name in (("corpus.blb", "ce"), ("corpus.json", "carrier"), ("corpus.bl", "text")):
            with open(os.path.join(CORPUS, file), "rb") as f:
                self.assertEqual(doors.guess(f.read())[0][1].name, name, file)

    def test_text_that_happens_to_be_ce(self):
        # "12" is also CE (the text "2"), and "0" (the empty text); as text they're JSON
        for data, want in ((b"12", bl("12")), (b"0", bl("0"))):
            self.assertGreater(doors.ce.sure(data), 0)
            self.assertEqual(doors.guess(data)[0][1].name, "json", data)
            self.assertEqual(doors.json.loads(data), want)

    def test_plain_text_is_nothing_in_particular(self):
        ranked = doors.guess(b"just some words, then more\n")
        self.assertTrue(all(s < doors.PLAUSIBLE for s, d in ranked), ranked)

    def test_extensions(self):
        for path, name in (("a.json", "json"), ("A.JSON", "json"), ("x/y.carrier.json", "carrier"),
                           ("a.jsonl", "json"), ("t.csv", "csv"), ("t.tsv", "tsv"),
                           ("v.blb", "ce"), ("v.bl", "text"), ("c.toml", "toml"),
                           ("p.svg", "xml"), ("c.yml", "yaml")):
            self.assertEqual(doors.by_extension(path).name, name, path)
        for path in ("noext", "a.txt", ".json"):
            self.assertIsNone(doors.by_extension(path), path)

    def test_named(self):
        self.assertIs(doors.named("json-entries"), doors.json.door)
        self.assertIs(doors.named("jsonl"), doors.json.door)
        with self.assertRaises(LookupError):
            doors.named("docx")

    def test_readings(self):
        found = list(doors.readings(b'{"a": 1}'))
        names = [r[1].name for r in found]
        self.assertEqual(names[0], "json")
        self.assertIn("text", names)
        self.assertIn("json-entries", names)
        self.assertEqual(found[names.index("text")][2], bl('{"a": 1}'))
        dup = [r[1].name for r in doors.readings(b'{"a": 1, "a": 2}')]
        self.assertNotIn("json", dup)
        self.assertEqual(dup[0], "json-entries")


if __name__ == "__main__":
    unittest.main()
