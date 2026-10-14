"""The JSON carrier: holds any value, refuses anything that isn't one."""

import json
import unittest

import _path  # noqa: F401
from gen import Gen
from bassline import Integer, NotHeld, bl, carrier


class Carrier(unittest.TestCase):
    def test_shape(self):
        self.assertEqual(carrier.to_carrier(bl("[nil go! 0xff]")), {
            "kind": "list", "value": [
                {"kind": "nil"},
                {"kind": "symbol", "mark": True, "value": "go"},
                {"kind": "bytes", "value": "0xff"},
            ]})
        self.assertEqual(carrier.to_carrier(bl("{a: 1}")), {
            "kind": "dict", "value": [[{"kind": "symbol", "value": "a"},
                                       {"kind": "number", "value": 1}]]})

    def test_json_text(self):
        v = bl('!(msg "h' + chr(0xE9) + '" 42 {k: v} {1 2} 0x)')
        text = carrier.to_json(v)
        self.assertEqual(json.loads(text), carrier.to_carrier(v))
        self.assertEqual(carrier.from_json(text), v)
        self.assertEqual(carrier.from_json(carrier.to_json(v, indent=4)), v)

    def test_integers_of_any_width(self):
        n = 3 * 10**5000 + 1
        text = carrier.to_json(Integer(-n))
        self.assertTrue(text.endswith("1}"))
        self.assertEqual(carrier.from_json(text), Integer(-n))
        self.assertEqual(carrier.from_json('{"kind": "number", "value": 18446744073709551616}'),
                         Integer(2**64))

    def test_mark_false_and_upper_hex_are_fine(self):
        self.assertEqual(carrier.from_json('{"kind": "nil", "mark": false}'), bl("nil"))
        self.assertEqual(carrier.from_json('{"kind": "bytes", "value": "0xDEad"}'),
                         bl("0xdead"))

    def test_members_in_any_order(self):
        text = ('{"kind": "set", "value": [{"kind": "number", "value": 3}, '
                '{"kind": "number", "value": 1}]}')
        self.assertEqual(carrier.from_json(text), bl("{1 3}"))

    def test_refusals(self):
        refused = [
            '{"kind": "number", "value": 1.5}',
            '{"kind": "number", "value": 1e3}',
            '{"kind": "number", "value": -0}',
            '{"kind": "number", "value": NaN}',
            '{"kind": "number", "value": Infinity}',
            '{"kind": "number", "value": true}',
            '{"kind": "number", "value": "1"}',
            '{"kind": "number"}',
            '{"kind": "nil", "value": null}',
            '{"kind": "nil", "mark": 1}',
            '{"kind": "nil", "extra": 1}',
            '{"kind": "nil", "kind": "nil"}',
            '{"kind": "boolean", "value": true}',
            '{"value": 1}',
            '{"kind": "text", "value": 1}',
            '{"kind": "text", "value": "\\ud800"}',
            '{"kind": "symbol", "value": null}',
            '{"kind": "bytes", "value": "ff"}',
            '{"kind": "bytes", "value": "0xf"}',
            '{"kind": "bytes", "value": "0xgg"}',
            '{"kind": "list", "value": {}}',
            '{"kind": "record", "value": []}',
            '{"kind": "dict", "value": [[{"kind": "nil"}]]}',
            '{"kind": "dict", "value": [{"kind": "nil"}]}',
            '{"kind": "dict", "value": [[{"kind": "nil"}, {"kind": "nil"}], '
            '[{"kind": "nil"}, {"kind": "nil"}]]}',
            '{"kind": "set", "value": [{"kind": "nil"}, {"kind": "nil"}]}',
            '[]',
            'true',
            '1',
            '{"kind": "list", "value": [1]}',
            'not json',
        ]
        for text in refused:
            with self.subTest(text), self.assertRaises(NotHeld):
                carrier.from_json(text)

    def test_random_values(self):
        for v in Gen(51).values(200):
            self.assertEqual(carrier.from_json(carrier.to_json(v)), v)


if __name__ == "__main__":
    unittest.main()
