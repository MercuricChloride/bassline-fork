"""Tests for the bassline Python package.

Run from ``blpy`` with ``python3 -m unittest discover -s tests``.
Each test module imports ``_path``, which puts ``src`` on the path, so
nothing needs installing. When the tests are imported as a package instead
(``-t .``), this puts the tests directory on the path for those imports.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
