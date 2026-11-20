"""Arrangements several doors share.

Numbers that aren't integers, and dates and times, are vocabulary: values
arranged so that receivers who know the words can read them.

- ``(dec m e)`` is m × 10^e, exactly as spelled: ``1.50`` is
  ``(dec 150 -2)``, keeping the precision the spelling states.
- ``(number "S")`` keeps a spelling that neither an integer nor a ``dec``
  holds: a negative zero (``-0``, ``-0.0``), an infinity or a NaN where the
  format has them.
- ``(date 2026 10 2)``, ``(time 7 32 0)`` (seconds as an integer, or a
  ``dec`` when they have a fraction), and ``(datetime (date …) (time …))``,
  with ``(offset M)`` last when the time is at an offset of M minutes east
  of UTC.
"""

from __future__ import annotations

import datetime as _dt
import re

from ..errors import NotHeld
from ..values import Integer, Kind, Record, Text, Value, _parse, rec, sym

DEC = sym.dec
NUMBER = sym.number
DATE = sym.date
TIME = sym.time
DATETIME = sym.datetime
OFFSET = sym.offset
TRUE = sym.true
FALSE = sym.false

_STRICT = re.compile(r"(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([-+]?[0-9]+))?\Z")
_LENIENT = re.compile(r"([-+]?)([0-9]*)(?:\.([0-9]*))?(?:[eE]([-+]?[0-9]+))?\Z")


def dec(m: int, e: int) -> Record:
    """``(dec m e)``: m × 10^e."""
    return rec(DEC, Integer(m), Integer(e))


def _int(digits: str) -> int:
    digits = digits.lstrip("0") or "0"
    return _parse(digits)


def number(spelling: str, *, lenient: bool = False) -> Value | None:
    """What a decimal number's spelling says, exactly: an integer when it
    has no fraction or exponent, ``(dec m e)`` when it has, and
    ``(number "S")`` for a negative zero, which neither can hold. ``None``
    when ``spelling`` isn't a decimal number.

    Strict spellings are JSON's: no ``+``, no leading zeros, digits on both
    sides of a point. ``lenient`` also takes a leading ``+``, leading zeros
    and a point with digits on one side only (``1.``, ``.5``), as YAML
    spells floats.
    """
    m = (_LENIENT if lenient else _STRICT).match(spelling)
    if m is None:
        return None
    sign, whole, frac, exp = m.groups()
    if lenient and not (whole or frac):
        return None
    negative = sign == "-"
    if frac is None and exp is None:
        n = _int(whole)
        if negative and n == 0:
            return rec(NUMBER, Text(spelling))
        return Integer(-n if negative else n)
    mant = _int(whole + (frac or ""))
    if negative and mant == 0:
        return rec(NUMBER, Text(spelling))
    e = 0
    if exp:
        e = _int(exp.lstrip("+-"))
        if exp.startswith("-"):
            e = -e
    e -= len(frac or "")
    return dec(-mant if negative else mant, e)


def is_dec(v: Value) -> bool:
    return (v.kind == Kind.RECORD and len(v) == 3 and v.head == DEC
            and v[1].kind == Kind.INTEGER and v[2].kind == Kind.INTEGER)


def dec_spelling(m: Integer, e: int) -> str:
    """The decimal spelling of ``(dec m e)`` that reads back as the same
    ``dec``: ``1.50`` for ``(dec 150 -2)``, ``1e3`` for ``(dec 1 3)``."""
    ms = m.spelling
    if e >= 0:
        return f"{ms}e{e}"
    negative = ms.startswith("-")
    digits = ms.lstrip("-")
    k = -e
    if k > len(digits) + 6:
        return f"{ms}e{e}"
    digits = digits.rjust(k + 1, "0")
    return ("-" if negative else "") + digits[:-k] + "." + digits[-k:]


def spelling(v: Value) -> str | None:
    """A number's decimal spelling: an integer's, a ``dec``'s, or the one a
    ``(number "S")`` keeps. ``None`` for anything else."""
    k = v.kind
    if k == Kind.INTEGER:
        return v.spelling
    if k != Kind.RECORD:
        return None
    if is_dec(v):
        return dec_spelling(v[1], v[2].value)
    if len(v) == 2 and v.head == NUMBER and v[1].kind == Kind.TEXT:
        return v[1].value
    return None


# ------------------------------------------------------------ dates and times


def date_record(year: int, month: int, day: int) -> Record:
    """``(date Y M D)``, refusing a day the calendar doesn't have."""
    try:
        _dt.date(year, month, day)
    except ValueError as e:
        raise NotHeld(f"no such date: {e}") from None
    return rec(DATE, year, month, day)


def time_record(hour: int, minute: int, second: int | str, fraction: str = "",
                offset: int | None = None) -> Record:
    """``(time H M S)``: the seconds an integer, or with the digits of
    ``fraction`` (exactly as spelled, trailing zeros and all) a ``dec``;
    ``(offset M)`` last when given."""
    sec = int(second)
    if not (0 <= hour < 24 and 0 <= minute < 60 and 0 <= sec < 61):
        raise NotHeld(f"no such time: {hour}:{minute}:{second}")
    s = dec(int(f"{sec}{fraction}"), -len(fraction)) if fraction else Integer(sec)
    fields = [Integer(hour), Integer(minute), s]
    if offset is not None:
        fields.append(_offset_record(offset))
    return rec(TIME, *fields)


def datetime_record(date: Record, time: Record, offset: int | None = None) -> Record:
    """``(datetime (date …) (time …))``, with ``(offset M)`` last when given."""
    fields = [date, time]
    if offset is not None:
        fields.append(_offset_record(offset))
    return rec(DATETIME, *fields)


def _offset_record(minutes: int) -> Record:
    if abs(minutes) >= 24 * 60:
        raise NotHeld(f"no such offset: {minutes} minutes")
    return rec(OFFSET, Integer(minutes))


def _offset_minutes(x) -> int | None:
    off = x.utcoffset()
    if off is None:
        return None
    seconds = int(off.total_seconds())
    if seconds % 60:
        raise NotHeld(f"an offset of {off} isn't whole minutes")
    return seconds // 60


def date_value(x: _dt.date | _dt.time, fraction: str | None = None) -> Record:
    """A host date, time or datetime as ``(date …)``, ``(time …)`` or
    ``(datetime (date …) (time …))``, with ``(offset M)`` last when it has
    one. ``fraction`` is the seconds' fraction as the document spelled it;
    without it, a fraction is the host's six digits of microseconds."""
    if isinstance(x, _dt.date) and not isinstance(x, _dt.datetime):
        return date_record(x.year, x.month, x.day)
    if fraction is None:
        fraction = f"{x.microsecond:06d}" if x.microsecond else ""
    t = x.timetz() if isinstance(x, _dt.datetime) else x
    off = _offset_minutes(x)
    if isinstance(x, _dt.datetime):
        return datetime_record(date_record(x.year, x.month, x.day),
                               time_record(t.hour, t.minute, t.second, fraction), off)
    return time_record(t.hour, t.minute, t.second, fraction, off)


def _ints(fields, n: int) -> list[int] | None:
    if len(fields) != n or any(f.kind != Kind.INTEGER or f.mark for f in fields):
        return None
    return [f.value for f in fields]


def _iso_date(v: Value) -> str | None:
    if v.kind != Kind.RECORD or v.head != DATE or v.mark:
        return None
    ymd = _ints(v.fields, 3)
    if ymd is None:
        return None
    try:
        return _dt.date(*ymd).isoformat()
    except (ValueError, OverflowError):
        return None


def _iso_offset(v: Value) -> str | None:
    if v.kind != Kind.RECORD or v.head != OFFSET or v.mark:
        return None
    m = _ints(v.fields, 1)
    if m is None or abs(m[0]) >= 24 * 60:
        return None
    if m[0] == 0:
        return "Z"
    sign = "-" if m[0] < 0 else "+"
    h, mm = divmod(abs(m[0]), 60)
    return f"{sign}{h:02d}:{mm:02d}"


def _iso_time(v: Value) -> tuple[str, str] | None:
    """A ``(time …)`` record as ``HH:MM:SS[.f]`` and its offset suffix."""
    if v.kind != Kind.RECORD or v.head != TIME or v.mark or len(v) not in (4, 5):
        return None
    hm = _ints(v.fields[:2], 2)
    s = v.fields[2]
    if hm is None or not (0 <= hm[0] < 24 and 0 <= hm[1] < 60):
        return None
    if s.kind == Kind.INTEGER and 0 <= s.value < 61:
        sec = f"{s.value:02d}"
    elif is_dec(s) and s[2].value < 0 and 0 <= s[1].value:
        sec = dec_spelling(s[1], s[2].value)
        whole, point, _ = sec.partition(".")
        if not point or not 0 <= int(whole) < 61:
            return None
        sec = whole.rjust(2, "0") + sec[len(whole):]
    else:
        return None
    off = ""
    if len(v) == 5:
        off = _iso_offset(v[4])
        if off is None:
            return None
    return f"{hm[0]:02d}:{hm[1]:02d}:{sec}", off


def iso(v: Value) -> str | None:
    """The RFC 3339 / ISO 8601 spelling of a ``date``, ``time`` or
    ``datetime`` record, or ``None`` if ``v`` isn't one."""
    if v.kind != Kind.RECORD or v.mark:
        return None
    if v.head == DATE:
        return _iso_date(v)
    if v.head == TIME:
        t = _iso_time(v)
        return None if t is None else t[0] + t[1]
    if v.head == DATETIME and len(v) in (3, 4):
        d, t = _iso_date(v[1]), _iso_time(v[2])
        if d is None or t is None or t[1]:
            return None
        off = ""
        if len(v) == 4:
            off = _iso_offset(v[3])
            if off is None:
                return None
        return f"{d}T{t[0]}{off}"
    return None


def date_kind(v: Value) -> str | None:
    """Which TOML date-time ``v`` spells, if any: ``"offset-datetime"``,
    ``"local-datetime"``, ``"local-date"``, ``"local-time"``."""
    s = iso(v)
    if s is None:
        return None
    if v.head == DATE:
        return "local-date"
    if v.head == TIME:
        return None if len(v) == 5 else "local-time"
    return "offset-datetime" if len(v) == 4 else "local-datetime"
