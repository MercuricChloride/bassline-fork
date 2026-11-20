"""Running the bin/ shims as subprocesses, the way a shell would."""

import os
import select
import subprocess
import sys

BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin")


def argv(tool, *args):
    """The command line for a shim, run by this interpreter (so a test run
    under a Python with PyYAML gives the tools PyYAML too)."""
    return [sys.executable, os.path.join(BIN, tool), *args]


def run(tool, *args, input=b"", cwd=None, timeout=60):
    return subprocess.run(argv(tool, *args), input=input, capture_output=True,
                          cwd=cwd, timeout=timeout)


def read_ready(f, n, timeout=10.0):
    """Up to ``n`` bytes from a pipe, waiting at most ``timeout`` seconds for
    the first of them; ``b""`` if nothing came."""
    ready, _, _ = select.select([f], [], [], timeout)
    if not ready:
        return b""
    return os.read(f.fileno(), n)


def read_exactly(f, n, timeout=10.0):
    got = b""
    while len(got) < n:
        b = read_ready(f, n - len(got), timeout)
        if not b:
            break
        got += b
    return got
