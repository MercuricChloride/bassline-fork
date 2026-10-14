"""Launch-local config injection and an opt-in real terminal UI proof."""

from contextlib import contextmanager
from copy import deepcopy
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import codex_relay as relay
from codex_socket import SocketRpc
from test_codex_socket import Events, completed, initialized, isolated_daemon, local_server
from websockets.sync.client import unix_connect
from websockets.sync.server import unix_serve


OPTIONS = {"mcp_servers.jam.command": "sh", "mcp_servers.jam.args": ["wrapper path"],
           "mcp_servers.jam.env.JAM_NAME": "fixture", "mcp_servers.jam.env.JAM_CODEX_PUSH": "1"}


class RelayTests(unittest.TestCase):
    def test_lifecycle_config_injected_and_existing_instructions_appended(self):
        for method in relay.THREAD_METHODS:
            original = {"id": "fixture", "method": method,
                        "params": {"threadId": "target", "developerInstructions": "existing instructions",
                                   "config": {"features": {"fixture": True},
                                              "mcp_servers": {"other": {"command": "other"}, "jam": {"command": "old"}},
                                              "mcp_servers.jam.command": "another old"},
                                   "dynamicTools": [{"name": "existing"}]}}
            kept = deepcopy(original)
            forwarded = relay.thread_request(original, OPTIONS, "trusted jam skill")
            self.assertEqual(original, kept)
            config = forwarded["params"]["config"]
            self.assertEqual(config["mcp_servers.jam"], {"command": "sh", "args": ["wrapper path"],
                                                       "env": {"JAM_NAME": "fixture", "JAM_CODEX_PUSH": "1"}})
            self.assertEqual(config["mcp_servers"], {"other": {"command": "other"}})
            self.assertEqual(config["features"], {"fixture": True})
            self.assertNotIn("mcp_servers.jam.command", config)
            self.assertEqual(forwarded["params"]["developerInstructions"], "existing instructions\n\ntrusted jam skill")
            self.assertEqual(forwarded["params"]["dynamicTools"], original["params"]["dynamicTools"])

    def test_non_lifecycle_requests_and_approval_decisions_are_untouched(self):
        for message in [{"id": "approval", "result": {"decision": "decline"}},
                        {"id": "tool", "method": "mcpServer/tool/call", "params": {"arguments": {"value": "full 🌊\nvalue"}}},
                        {"method": "initialized", "params": {}}]:
            self.assertIs(relay.thread_request(message, OPTIONS, "skill"), message)

    def test_relay_forwards_server_requests_and_explicit_decisions_without_generating_rpc(self):
        received = []

        def upstream(host):
            received.append(json.loads(host.recv()))
            host.send('{"id":"approval-fixture","method":"item/commandExecution/requestApproval","params":{"command":"fixture"}}')
            received.append(json.loads(host.recv()))
            host.send('{"id":"first","result":{"complete":true}}')

        with local_server(upstream) as upstream_path:
            with local_server(relay.handler(upstream_path, OPTIONS)) as ui_path:
                with unix_connect(ui_path, compression=None) as ui:
                    ui.send('{"id":"first","method":"thread/start","params":{"config":null}}')
                    request = json.loads(ui.recv())
                    self.assertEqual(request["id"], "approval-fixture")
                    self.assertEqual(len(received), 1)
                    decision = {"id": "approval-fixture", "result": {"decision": "decline"}}
                    ui.send(json.dumps(decision))
                    self.assertEqual(json.loads(ui.recv()), {"id": "first", "result": {"complete": True}})
                    self.assertEqual(received[1], decision)
        self.assertEqual(len(received), 2)

    def test_foreground_exit_status_and_sigint_ownership_are_preserved(self):
        previous = signal.getsignal(signal.SIGINT)
        leases = []

        class Process:
            def wait(self):
                self_handler = signal.getsignal(signal.SIGINT)
                self_handler(signal.SIGINT, None)
                lease = Path(leases[0])
                self_test.assertTrue(lease.is_absolute())
                self_test.assertEqual(lease.stat().st_mode & 0o777, 0o600)
                with lease.open("rb") as candidate:
                    with self_test.assertRaises(BlockingIOError):
                        fcntl.flock(candidate, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return 7

            def poll(self):
                return 7

        self_test = self
        original_handler = relay.handler

        def capture(upstream, options, instructions):
            leases.append(options["mcp_servers.jam.env.JAM_CODEX_LEASE"])
            return original_handler(upstream, options, instructions)

        with patch.object(relay, "handler", side_effect=capture), \
                patch.object(relay.subprocess, "Popen", return_value=Process()) as launch:
            self.assertEqual(relay.launch("fixture-codex", ["resume", "--last"], "/unused", OPTIONS), 7)
            argv = launch.call_args.args[0]
            self.assertEqual(argv[:2], ["fixture-codex", "--remote"])
            self.assertTrue(argv[2].startswith("unix:///tmp/jam-codex-ui-"))
            self.assertEqual(argv[3:], ["resume", "--last"])
            self.assertFalse(Path(argv[2].removeprefix("unix://")).exists())
            self.assertFalse(Path(leases[0]).exists())
        self.assertIs(signal.getsignal(signal.SIGINT), previous)

    def test_kernel_releases_launch_lease_when_relay_is_killed(self):
        program = '''import json,sys,time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import codex_relay as relay
original = relay.handler
def capture(upstream, options, instructions):
 print(options["mcp_servers.jam.env.JAM_CODEX_LEASE"],flush=True)
 return original(upstream, options, instructions)
relay.handler = capture
class Process:
 def wait(self):time.sleep(300)
 def poll(self):return None
relay.subprocess.Popen = lambda *args,**kwargs: Process()
relay.launch("unused", [], "/unused", {})
'''
        child = subprocess.Popen([sys.executable, "-c", program, str(Path(relay.__file__).parent)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        lease = None
        try:
            self.assertTrue(select.select([child.stdout], [], [], 5)[0])
            lease = Path(child.stdout.readline().strip())
            self.assertTrue(lease.is_file())
            with lease.open("rb") as candidate:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(candidate, fcntl.LOCK_EX | fcntl.LOCK_NB)
                child.kill()
                child.wait(3)
                fcntl.flock(candidate, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(candidate, fcntl.LOCK_UN)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(3)
            child.stdout.close()
            child.stderr.close()
            if lease is not None:
                shutil.rmtree(lease.parent)


@contextmanager
def terminal(binary, endpoint, environment, root, arguments=()):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    process = subprocess.Popen([binary, "--remote", "unix://" + str(endpoint), "--no-alt-screen", *arguments],
                               env=dict(environment, TERM="xterm-256color"), cwd=root,
                               stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    stopped = threading.Event()
    screen = bytearray()

    def drain():
        while not stopped.is_set():
            if not select.select([master], [], [], .1)[0]:
                continue
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            screen.extend(data)

    draining = threading.Thread(target=drain, daemon=True)
    draining.start()
    try:
        yield process, screen
    finally:
        process.terminate()
        try:
            process.wait(3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(3)
        stopped.set()
        draining.join(2)
        os.close(master)


@unittest.skipUnless(os.environ.get("JAM_CODEX_TEST_BINARY"), "Set JAM_CODEX_TEST_BINARY for an isolated terminal UI test")
class TerminalRuntimeTests(unittest.TestCase):
    def test_actual_new_and_resumed_tui_initialize_per_thread_mcp_without_inference(self):
        binary = os.environ["JAM_CODEX_TEST_BINARY"]
        with isolated_daemon(binary) as (root, upstream, model, environment):
            with Path(root, "config.toml").open("a") as config:
                config.write('\n[projects.' + json.dumps(root) + ']\ntrust_level="trusted"\n')
            fake = Path(root, "fake_mcp.py")
            log = Path(root, "mcp.jsonl")
            fake.write_text('import json,os,sys\n'
                            'with open(sys.argv[1],"a") as f:f.write(json.dumps({"pid":os.getpid()})+"\\n")\n'
                            'for line in sys.stdin:\n'
                            ' q=json.loads(line)\n'
                            ' with open(sys.argv[1],"a") as f:f.write(json.dumps(q)+"\\n")\n'
                            ' if "id" not in q:continue\n'
                            ' r={"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}} if q["method"]=="initialize" else {"tools":[]} if q["method"]=="tools/list" else {}\n'
                            ' print(json.dumps({"jsonrpc":"2.0","id":q["id"],"result":r}),flush=True)\n'
                            'with open(sys.argv[1],"a") as f:f.write(json.dumps({"eof":True})+"\\n")\n')
            options = {"mcp_servers.jam.command": sys.executable,
                       "mcp_servers.jam.args": [str(fake), str(log)]}
            events = Events()
            endpoint = Path(root, "tui.sock")
            with unix_serve(relay.handler(upstream, options, "trusted fixture jam skill", events.add),
                            str(endpoint), compression=None, max_size=None) as server:
                serving = threading.Thread(target=server.serve_forever, daemon=True)
                serving.start()
                try:
                    with terminal(binary, endpoint, environment, root) as (process, screen):
                        new = events.wait(lambda m: m.get("method") == "thread/start")
                        self.assertIn("mcp_servers.jam", new["params"]["config"])
                        self.assertIn("trusted fixture jam skill", new["params"]["developerInstructions"])
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            records = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
                            if any(record.get("method") == "initialize" for record in records):
                                break
                            time.sleep(.05)
                        self.assertTrue(any(record.get("method") == "initialize" for record in records), repr(screen[-4000:]))
                        self.assertIsNone(process.poll())
                    first_pid = next(record["pid"] for record in records if "pid" in record)
                    # The daemon retains its per-thread MCP process after the
                    # terminal closes. A wake worker needs a separate UI lease.
                    os.kill(first_pid, 0)
                    ui_events = Events()
                    ui = initialized(upstream, ui_events)
                    try:
                        threads = ui.call("thread/loaded/list", {})["data"]
                        self.assertEqual(len(threads), 1)
                        thread = threads[0]
                        # Persist a separate thread with one explicit fake
                        # response; an empty thread has no resumable rollout.
                        bare = ui.call("thread/start", {"cwd": root, "historyMode": "paginated", "threadSource": "user",
                                                        "approvalPolicy": "never", "sandbox": "read-only"})["thread"]["id"]
                        seeded = ui.call("turn/start", {"threadId": bare, "input": [{"type": "text", "text": "persist isolated fixture"}]})["turn"]["id"]
                        completed(ui_events, seeded)
                        ui.call("thread/unsubscribe", {"threadId": bare})
                        before = len([r for r in records if r.get("method") == "initialize"])
                        with terminal(binary, endpoint, environment, root, ["resume", bare]) as (process, screen):
                            resumed = events.wait(lambda m: m.get("method") == "thread/resume" and m.get("params", {}).get("threadId") == bare)
                            self.assertIn("mcp_servers.jam", resumed["params"]["config"])
                            deadline = time.monotonic() + 10
                            while time.monotonic() < deadline:
                                records = [json.loads(line) for line in log.read_text().splitlines()]
                                if len([r for r in records if r.get("method") == "initialize"]) > before:
                                    break
                                time.sleep(.05)
                            self.assertGreater(len([r for r in records if r.get("method") == "initialize"]), before, repr(screen[-4000:]))
                            self.assertIsNone(process.poll())
                    finally:
                        ui.close()
                    self.assertEqual(len(model.requests), 1)
                finally:
                    server.shutdown()
                    serving.join(3)


if __name__ == "__main__":
    unittest.main()
