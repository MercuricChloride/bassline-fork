"""TSV: a table as a list of rows, each a list of text cells.

Cells are separated by tabs and rows by line breaks, and that is all: no
quoting, so a quote is part of its cell. A cell holding a tab or a line
break can't be written, and the writer refuses it. Otherwise as
:mod:`bassline.doors.csv`.
"""

from __future__ import annotations

import csv as _csv
import io

from .csv import CSVDoor

__all__ = ["door", "read", "loads", "dumps", "writer", "sure"]


class TSVDoor(CSVDoor):
    name = "tsv"
    summary = "tab-separated values: rows of text cells, no quoting"
    extensions = (".tsv", ".tab")
    readings = ("tsv",)
    writers = ("tsv",)
    delimiter = "\t"

    def _reader(self, text: str):
        return _csv.reader(io.StringIO(text, newline=""), delimiter="\t",
                           quoting=_csv.QUOTE_NONE, strict=True)

    def _writer_for(self, out):
        return _csv.writer(out, delimiter="\t", quoting=_csv.QUOTE_NONE,
                           quotechar=None, escapechar=None, lineterminator="\n")


door = TSVDoor()
read = door.read
loads = door.loads
dumps = door.dumps
writer = door.writer
sure = door.sure
