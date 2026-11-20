"""A launcher lease is a local lock, released by the kernel when its UI ends."""

import importlib.util
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


PLUGIN = Path(__file__).resolve().parents[1]
SOURCE = PLUGIN / "scripts" / "codex_bridge.py"
SPEC = importlib.util.spec_from_file_location("jam_codex_lease_tests", SOURCE)
bridge = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bridge
SPEC.loader.exec_module(bridge)


class LeaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="codex jam lease ")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "launcher.lease"
        self.contents = b"a local launcher lease\n"
        self.path.write_bytes(self.contents)
        self.path.chmod(0o400)
        self.before = self.path.stat()

    def assert_unchanged(self):
        self.assertEqual(self.path.read_bytes(), self.contents)
        after = self.path.stat()
        self.assertEqual(after.st_mtime_ns, self.before.st_mtime_ns)
        self.assertEqual(after.st_mode, self.before.st_mode)

    def alive(self, path):
        with patch.dict(os.environ, {"JAM_CODEX_LEASE": str(path)}):
            return bridge.launch_alive()

    def hold_in_other_process(self):
        code = (
            "import fcntl, signal, sys\n"
            "with open(sys.argv[1], 'rb') as lease:\n"
            "    fcntl.flock(lease, fcntl.LOCK_EX)\n"
            "    print('locked', flush=True)\n"
            "    while True: signal.pause()\n"
        )
        holder = subprocess.Popen([sys.executable, "-u", "-c", code, str(self.path)],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)

        def stop():
            if holder.poll() is None:
                holder.terminate()
                try:
                    holder.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    holder.kill()
                    holder.wait(timeout=3)
            holder.stdout.close()
            holder.stderr.close()

        self.addCleanup(stop)
        ready, _, _ = select.select([holder.stdout], [], [], 3)
        self.assertTrue(ready, "the isolated lock holder starts within the deadline")
        self.assertEqual(holder.stdout.readline(), "locked\n")
        return holder

    def test_without_launcher_lease_the_adapter_is_available(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertTrue(bridge.launch_alive())
        self.assert_unchanged()

    def test_missing_lease_is_dead_without_creating_a_file(self):
        missing = self.path.with_name("missing.lease")
        self.assertFalse(self.alive(missing))
        self.assertFalse(missing.exists())
        self.assert_unchanged()

    def test_unlocked_abandoned_lease_is_dead(self):
        self.assertFalse(self.alive(self.path))
        self.assertFalse(self.alive(self.path))
        self.assert_unchanged()

    def test_live_process_holding_readonly_lease_is_alive(self):
        holder = self.hold_in_other_process()
        self.assertIsNone(holder.poll())
        self.assertTrue(self.alive(self.path))
        self.assertTrue(self.alive(self.path))
        self.assert_unchanged()

    def test_abruptly_killed_holder_releases_lease_without_cleanup(self):
        holder = self.hold_in_other_process()
        self.assertTrue(self.alive(self.path))
        holder.kill()
        holder.wait(timeout=3)
        self.assertLess(holder.returncode, 0)
        self.assertFalse(self.alive(self.path))
        self.assert_unchanged()


if __name__ == "__main__":
    unittest.main()
