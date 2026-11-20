"""Searches and streams: the combinators, and Heard."""

import threading
import unittest
from itertools import count, repeat

import _path  # noqa: F401
from bassline import (
    Heard,
    alt,
    alt_from,
    bl,
    doors,
    fan,
    feed,
    first,
    rec,
    sym,
    take,
    through,
)
from bassline.doors import Door


def counted(stream, log, name):
    """``stream``, noting each pull in ``log``."""
    for a in stream:
        log.append(name)
        yield a


class Alt(unittest.TestCase):
    def test_turns(self):
        self.assertEqual(list(alt([1, 2, 3], "ab")), [1, "a", 2, "b", 3])

    def test_finished_streams_drop_out(self):
        self.assertEqual(list(alt([1, 2, 3], [], ["x"])), [1, "x", 2, 3])
        self.assertEqual(list(alt()), [])

    def test_fair_beside_an_endless_stream(self):
        answers = take(alt(count(), "abc"), 6)
        self.assertEqual(answers, [0, "a", 1, "b", 2, "c"])
        self.assertEqual(take(alt(repeat("x"), "ab", count()), 9),
                         ["x", "a", 0, "x", "b", 1, "x", 2, "x"])

    def test_pulls_only_what_is_taken(self):
        log = []
        take(alt(counted(count(), log, "a"), counted(count(), log, "b")), 3)
        self.assertEqual(log, ["a", "b", "a"])


class AltFrom(unittest.TestCase):
    def test_fair_over_a_stream_of_streams(self):
        self.assertEqual(list(alt_from([[1, 2, 3], "ab", []])), [1, 2, "a", 3, "b"])

    def test_admits_lazily(self):
        pulled = []

        def source():
            for name in "abc":
                pulled.append(name)
                yield repeat(name)

        s = alt_from(source())
        self.assertEqual(next(s), "a")
        self.assertEqual(pulled, ["a"])          # nothing asked of the source ahead of need
        self.assertEqual(take(s, 5), ["a", "b", "a", "b", "c"])   # a | a b | a b c
        self.assertEqual(pulled, ["a", "b", "c"])

    def test_a_late_newcomer_joins(self):
        # the source has nothing new for a while, then learns of a stream
        def source():
            yield repeat("first")
            for _ in range(3):
                yield iter(())                     # nothing new this round
            yield repeat("late")

        answers = take(alt_from(source()), 12)
        self.assertIn("late", answers)
        late = answers.index("late")
        self.assertEqual(answers[late:late + 4], ["late", "first", "late", "first"])

    def test_an_endless_supply_does_not_hold_up_the_first(self):
        s = alt_from(count(i * 100) for i in count())
        answers = take(s, 10)
        self.assertEqual(answers[0], 0)
        self.assertEqual(sum(1 for a in answers if a < 100), 4)   # stream 0 keeps answering
        self.assertIn(300, answers)                                # and newcomers keep joining


class Feed(unittest.TestCase):
    def test_each_answer_asked_again(self):
        answers = list(feed([1, 2, 3], lambda n: repeat(n, n)))
        self.assertEqual(sorted(answers), [1, 2, 2, 3, 3, 3])

    def test_an_endless_answer_does_not_starve_the_next(self):
        answers = take(feed(["a", "b"], lambda x: repeat(x)), 6)
        self.assertEqual(answers, ["a", "a", "b", "a", "b", "a"])

    def test_asks_only_when_needed(self):
        asked = []

        def search(x):
            asked.append(x)
            return iter((x * 10,))

        s = feed(count(1), search)
        self.assertEqual(next(s), 10)
        self.assertEqual(asked, [1])


class FirstAndTake(unittest.TestCase):
    def test_first(self):
        self.assertEqual(first(count(5)), 5)
        self.assertIsNone(first(iter(())))
        self.assertEqual(first([], default="none"), "none")

    def test_take_pulls_no_more(self):
        log = []
        self.assertEqual(take(counted(count(), log, "x"), 3), [0, 1, 2])
        self.assertEqual(len(log), 3)
        self.assertEqual(take("ab", 5), ["a", "b"])


class Combining(unittest.TestCase):
    def test_fan(self):
        both = fan(lambda q: repeat(q), lambda q: iter((q + 1, q + 2)))
        self.assertEqual(take(both(10), 5), [10, 11, 10, 12, 10])

    def test_through(self):
        double = lambda n: iter((n, n))
        plus = lambda n: iter((n + 1,))
        self.assertEqual(list(through(double, plus)(1)), [2, 2])
        self.assertEqual(list(through()(7)), [7])


class WorksWhenAsked(unittest.TestCase):
    """doors.readings sizes the doors up when asked and reads as pulled."""

    def test_readings_ranks_on_asking_and_reads_on_pulling(self):
        log = []

        class Probe(Door):
            readings = writers = ()

            def __init__(self, name, sureness):
                self.name, self.sureness = name, sureness
                self.readings = (name,)

            def sure(self, data):
                log.append(("sure", self.name))
                return self.sureness

            def _read(self, data, reading):
                log.append(("read", self.name))
                return iter((sym(self.name),))

        stream = doors.readings(b"doc", [Probe("low", 30), Probe("high", 80)])
        self.assertEqual(sorted(log), [("sure", "high"), ("sure", "low")])
        self.assertEqual(next(stream), rec(sym.reading, sym.high, sym.high))
        self.assertEqual(log[-1], ("read", "high"))
        self.assertNotIn(("read", "low"), log)


class HeardTests(unittest.TestCase):
    def test_a_send_that_keeps_each_value_once(self):
        h = Heard()
        self.assertIs(h.add(bl("(a 1)")), True)
        self.assertIs(h(bl("(a 1)")), True)
        h.add([1, 2])
        self.assertEqual(list(h), [bl("(a 1)"), bl("[1 2]")])
        self.assertIn(bl("[1 2]"), h)

    def test_streams_see_what_arrives_while_pulled(self):
        h = Heard([bl("(a 1)")])
        s = iter(h)
        self.assertEqual(next(s), bl("(a 1)"))
        h.add(bl("(a 2)"))
        self.assertEqual(next(s), bl("(a 2)"))
        self.assertIsNone(first(s))
        h.add(bl("(a 3)"))
        self.assertEqual(list(iter(h))[-1], bl("(a 3)"))   # asking again sees it

    def test_under(self):
        h = Heard(bl(t) for t in ["(person ada)", "(personal x)", "!(person m)",
                                  "(person bob)"])
        self.assertEqual(list(h.under(bl("(person)"))),
                         [bl("(person ada)"), bl("(person bob)")])

    def test_fed_from_another_thread(self):
        h = Heard()
        t = threading.Thread(target=lambda: [h.add(i) for i in range(1000)])
        t.start()
        t.join()
        self.assertEqual(len(h), 1000)


if __name__ == "__main__":
    unittest.main()
