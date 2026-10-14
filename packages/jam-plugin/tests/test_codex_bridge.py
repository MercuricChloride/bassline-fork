"""The Codex edge, exercised without a real jam or model generation."""

import importlib.util
import json
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
sys.path.insert(0, str(SOURCE.parent))
SPEC = importlib.util.spec_from_file_location("jam_codex_bridge", SOURCE)
bridge = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bridge
SPEC.loader.exec_module(bridge)
from bassline import Bytes

THREAD = "00000000-0000-4000-8000-000000000001"
OTHER_THREAD = "00000000-0000-4000-8000-000000000002"


def heard(rank, identity=None, room=None):
    return bridge.rec(
        bridge.sym.heard,
        room or bridge.rec(bridge.sym("for"), bridge.Text("test-reader")),
        bridge.Integer(rank),
        bridge.Dict({bridge.sym.digest: bridge.Text(identity or f"record-{rank}")}),
        bridge.Set([
            bridge.rec(bridge.sym.said, bridge.Text(f"arrived {rank}: λ\n!{{marked}}")),
            bridge.rec(bridge.sym.integer, bridge.Integer(10**80 + rank)),
            bridge.rec(bridge.sym.bytes, Bytes(b"\x00\xff\x80", mark=True)),
        ], mark=True),
    )


def mcp_result(records):
    return {"content": [{"type": "text", "text": "\n".join(
        bridge.to_text(value) for value in records) if records else "nothing heard fits"}]}


class Host:
    def __init__(self, refusal=None):
        self.refusal = refusal
        self.calls = []

    def call(self, method, params, **kwargs):
        self.calls.append((method, params))
        if self.refusal:
            raise self.refusal
        return {}


class HeldRecords:
    def __init__(self, records):
        self.records = records
        self.arguments = []

    def call(self, method, params, **kwargs):
        self.arguments.append(params["arguments"])
        args = params["arguments"]
        found = sorted((value for value in self.records
                        if value.fields[1].value > args["since"]),
                       key=lambda value: value.fields[1].value)
        return mcp_result(found[:args["first"]])


class InboxTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.inbox = bridge.Inbox(self.directory.name, THREAD, "test-reader", "local-test")
        self.inbox.initialize(-1)

    def tearDown(self):
        self.inbox.close()
        self.directory.cleanup()

    def reopen(self):
        self.inbox.close()
        self.inbox = bridge.Inbox(self.directory.name, THREAD, "test-reader", "local-test")

    def test_pending_and_accepted_survive_restart_independently(self):
        records = [heard(3), heard(1), heard(2)]
        self.inbox.offer(records)
        self.inbox.accept([records[1]])
        self.reopen()
        self.inbox.initialize(10000)
        self.assertEqual(self.inbox.cursor, 3)
        self.assertEqual(self.inbox.floor, -1)
        self.assertEqual(self.inbox.pending, [records[2], records[0]])
        self.inbox.offer([heard(1)])
        self.assertEqual(self.inbox.pending, [records[2], records[0]])

    def test_host_refusal_leaves_saved_records_pending_for_retry(self):
        value = heard(7)
        self.inbox.offer([value])
        host = Host(bridge.BridgeError("host cannot take this output"))
        wake = bridge.Wake(None, host, self.inbox, THREAD)
        with self.assertRaises(bridge.BridgeError):
            wake.deliver_once()
        self.reopen()
        self.assertEqual(self.inbox.pending, [value])
        host.refusal = None
        bridge.Wake(None, host, self.inbox, THREAD).deliver_once()
        self.reopen()
        self.assertEqual(self.inbox.pending, [])

    def test_failed_save_does_not_advance_cursor_or_replace_snapshot(self):
        self.inbox.offer([heard(1)])
        saved = self.inbox.path.read_bytes()
        with patch.object(self.inbox, "_save", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.inbox.offer([heard(2)])
        self.assertEqual(self.inbox.cursor, 1)
        self.assertEqual(self.inbox.pending, [heard(1)])
        self.assertEqual(self.inbox.path.read_bytes(), saved)

    def test_failed_acceptance_save_keeps_delivery_for_recovery(self):
        value = heard(1)
        self.inbox.offer([value])
        host = Host()
        with patch.object(self.inbox, "_save", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                bridge.Wake(None, host, self.inbox, THREAD).deliver_once()
        self.assertEqual(len(host.calls), 1)
        self.reopen()
        self.assertEqual(self.inbox.pending, [value])

    def test_same_reader_has_one_delivery_owner(self):
        with self.assertRaises(bridge.BridgeError):
            bridge.Inbox(self.directory.name, THREAD, "test-reader", "local-test")
        other = bridge.Inbox(self.directory.name, THREAD, "another-reader", "local-test")
        other.close()

    def test_duplicate_identity_is_suppressed_per_room(self):
        first = heard(1, "same-value")
        self.inbox.offer([first, heard(2, "same-value")])
        self.assertEqual(self.inbox.pending, [first])
        self.inbox.accept([first])
        other_room = heard(4, "same-value", bridge.sym.another_room)
        self.inbox.offer([heard(3, "same-value"), other_room, heard(5, "another-value")])
        self.assertEqual(self.inbox.pending, [other_room, heard(5, "another-value")])
        self.assertEqual(self.inbox.cursor, 5)

    def test_oldest_pages_collect_more_than_default_thirty(self):
        records = [heard(rank) for rank in range(75, 0, -1)]
        backend = HeldRecords(records)
        wake = bridge.Wake(backend, Host(), self.inbox, THREAD, batch_size=7)
        while True:
            wake.poll_once(wait=0)
            if wake.round_done:
                break
        self.assertEqual(self.inbox.pending, list(reversed(records)))
        self.assertEqual(self.inbox.cursor, 75)
        self.assertEqual([args["since"] for args in backend.arguments],
                         [-1, 7, 14, 21, 28, 35, 42, 49, 56, 63, 70])
        self.assertTrue(all(args.get("first") == 7 and "last" not in args
                            for args in backend.arguments))

    def test_later_understanding_can_deliver_an_earlier_rank(self):
        later = heard(9)
        backend = HeldRecords([later])
        wake = bridge.Wake(backend, Host(), self.inbox, THREAD, batch_size=7)
        wake.poll_once(wait=0)
        self.assertTrue(wake.round_done)
        self.inbox.accept([later])
        earlier = heard(1)
        backend.records = [earlier, later]
        wake.poll_once(wait=0)
        self.assertEqual(self.inbox.cursor, 9)
        self.assertEqual(self.inbox.pending, [earlier])
        self.assertEqual([args["since"] for args in backend.arguments], [-1, -1])

    def test_same_joined_rank_below_cursor_is_normal(self):
        self.inbox.offer([heard(9)])
        result = mcp_result([heard(10)])
        result["_meta"] = {"jam": {"joinedRank": 2}}
        backend = Host()
        backend.call = lambda *args, **kwargs: result
        wake = bridge.Wake(backend, None, self.inbox, THREAD, joined_rank=2)
        wake.poll_once(wait=0)
        self.assertEqual(self.inbox.cursor, 10)
        self.assertEqual(wake.joined_rank, 2)

    def test_changed_joined_rank_below_cursor_refuses_before_offer(self):
        self.inbox.offer([heard(9)])
        saved = self.inbox.path.read_bytes()
        result = mcp_result([heard(10)])
        result["_meta"] = {"jam": {"joinedRank": 3}}
        backend = Host()
        backend.call = lambda *args, **kwargs: result
        wake = bridge.Wake(backend, None, self.inbox, THREAD, joined_rank=2)
        with self.assertRaises(bridge.RanksRestarted):
            wake.poll_once(wait=0)
        self.assertEqual(self.inbox.path.read_bytes(), saved)
        self.assertEqual(self.inbox.cursor, 9)
        self.assertEqual(self.inbox.pending, [heard(9)])

    def test_tool_output_preserves_whole_marked_values_in_order(self):
        records = [heard(3), heard(1), heard(2)]
        self.inbox.offer(records)
        host = Host()
        wake = bridge.Wake(None, host, self.inbox, THREAD, batch_size=2)
        self.assertEqual(wake.deliver_once(), [records[1], records[2]])
        method, params = host.calls[0]
        self.assertEqual(method, "turn/start")
        self.assertEqual(params["threadId"], THREAD)
        self.assertEqual(params["input"], [])
        output = params["toolOutput"]
        self.assertEqual((output["namespace"], output["name"]), ("jam", "heard"))
        landed = bridge.parse_records({"content": [{"type": "text", "text": output["output"]}]})
        self.assertEqual([bridge.encode(value) for value in landed],
                         [bridge.encode(value) for value in [records[1], records[2]]])
        self.assertEqual(self.inbox.pending, [records[0]])

    def test_refused_heard_read_does_not_advance_cursor(self):
        backend = Host()
        backend.call = lambda *args, **kwargs: {"isError": True, "content": []}
        with self.assertRaises(bridge.BridgeError):
            bridge.Wake(backend, None, self.inbox, THREAD).poll_once(wait=0)
        self.assertEqual(self.inbox.cursor, -1)
        self.assertEqual(self.inbox.pending, [])

    def test_unreadable_batch_is_refused_before_any_cursor_advance(self):
        backend = Host()
        bad = bridge.rec(bridge.sym.heard, bridge.sym.room, bridge.Text("rank"),
                         bridge.Dict(), bridge.sym.value)
        backend.call = lambda *args, **kwargs: mcp_result([heard(1), bad])
        with self.assertRaises(bridge.BridgeError):
            bridge.Wake(backend, None, self.inbox, THREAD).poll_once(wait=0)
        self.reopen()
        self.assertEqual(self.inbox.cursor, -1)
        self.assertEqual(self.inbox.pending, [])


class BindingTests(unittest.TestCase):
    def test_call_metadata_overrides_no_shell_ancestry(self):
        with patch.dict(os.environ, {"CODEX_THREAD_ID": OTHER_THREAD,
                                     "CODEX_SESSION_ID": OTHER_THREAD}):
            binding = bridge.Binding()
            self.assertIsNone(binding.thread)
            self.assertFalse(binding.ready.is_set())
            binding.observe({"_meta": {"threadId": THREAD}})
        self.assertEqual(binding.thread, THREAD)
        self.assertTrue(binding.ready.is_set())

    def test_an_adapter_cannot_change_thread_after_binding(self):
        binding = bridge.Binding(THREAD)
        with self.assertRaises(bridge.BridgeError):
            binding.observe({"_meta": {"threadId": OTHER_THREAD}})
        self.assertEqual(binding.thread, THREAD)


class RpcTests(unittest.TestCase):
    def test_interleaved_notifications_and_out_of_order_results(self):
        script = """import json,sys
waiting=[]
for line in sys.stdin:
 q=json.loads(line)
 if 'id' not in q:continue
 waiting.append(q)
 if len(waiting)==2:
  print(json.dumps({'method':'probe/changed','params':{'value':'λ'}}),flush=True)
  for q in reversed(waiting):
   print(json.dumps({'id':q['id'],'result':q['params']}),flush=True)
  waiting=[]
"""
        notifications = []
        rpc = bridge.Rpc([sys.executable, "-c", script], notifications.append)
        try:
            first = rpc.request("first", {"value": 1})
            second = rpc.request("second", {"value": 2})
            self.assertEqual(second.result(3), {"value": 2})
            self.assertEqual(first.result(3), {"value": 1})
            self.assertEqual(notifications, [{"method": "probe/changed", "params": {"value": "λ"}}])
        finally:
            rpc.close()
        self.assertIsNotNone(rpc.process.poll())

    def test_json_error_and_pipe_end_are_refusals(self):
        script = """import json,sys
q=json.loads(sys.stdin.readline())
print(json.dumps({'id':q['id'],'error':{'code':-32000,'message':'refused'}}),flush=True)
sys.stdin.readline()
"""
        rpc = bridge.Rpc([sys.executable, "-c", script])
        try:
            with self.assertRaisesRegex(bridge.BridgeError, "refused"):
                rpc.call("initialize", {}, timeout=3)
            with self.assertRaises(bridge.BridgeError):
                rpc.call("after_end", {}, timeout=3)
        finally:
            rpc.close()


class PackagingTests(unittest.TestCase):
    def test_mcp_backend_arguments_keep_their_order(self):
        argv = [str(SOURCE), "--mcp", "--at", "127.0.0.1:9999", "--hear", "all"]
        with patch.object(sys, "argv", argv), patch.object(bridge, "run_mcp") as run:
            bridge.main()
        run.assert_called_once_with(["--at", "127.0.0.1:9999", "--hear", "all"])

    def test_launcher_keeps_tui_and_adapter_on_the_same_host(self):
        with tempfile.TemporaryDirectory() as directory:
            socket = Path(directory) / "app server.sock"
            socket.touch()
            socket = socket.resolve()
            env = {"JAM_CODEX_SOCKET": str(socket), "JAM_CODEX_CODEX": "codex-fixture"}
            with patch.dict(os.environ, env), \
                    patch("codex_relay.launch", return_value=7) as execute, \
                    patch.object(bridge.shutil, "which", return_value="/fixture/codex"):
                self.assertEqual(bridge.launch("test-reader", ["--no-alt-screen", "join the jam"]), 7)
            executable, arguments, upstream, config, instructions = execute.call_args.args
            self.assertEqual(executable, "codex-fixture")
            self.assertEqual(upstream, socket)
            self.assertEqual(arguments, ["--no-alt-screen", "join the jam"])
            self.assertEqual(config["mcp_servers.jam.env.JAM_CODEX_PUSH"], "1")
            self.assertEqual(config["mcp_servers.jam.env.JAM_CODEX_SOCKET"], str(socket))
            self.assertEqual(instructions, (PLUGIN / "skills" / "jam" / "SKILL.md").read_text())

    def test_push_wrapper_can_bind_from_later_mcp_call(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "scripts").mkdir()
            wrapper = root / "bin" / "jam-codex-mcp"
            wrapper.write_bytes((PLUGIN / "bin" / "jam-codex-mcp").read_bytes())
            (root / "bin" / "jam-mcp").write_text("#!/bin/sh\nprintf 'tools-only\\n'\n")
            (root / "bin" / "jam-mcp").chmod(0o755)
            (root / "scripts" / "codex_bridge.py").write_text("print('wake-bridge')\n")
            env = dict(os.environ, JAM_NAME="test-reader", JAM_CODEX_PUSH="1")
            env.pop("JAM_CODEX_THREAD", None)
            result = subprocess.run(["sh", str(wrapper)], env=env, text=True,
                                    capture_output=True, check=True, timeout=3)
            self.assertEqual(result.stdout.strip(), "wake-bridge")

    def test_tools_pass_through_when_wake_host_is_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            backend = root / "bin" / "jam-mcp"
            backend.write_text("""#!/usr/bin/env python3
import json,sys
initialized=False
for line in sys.stdin:
 q=json.loads(line)
 if 'id' not in q:
  if q['method']=='notifications/initialized':initialized=True
  continue
 if q['method']=='initialize':
  result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'fake-jam','version':'1'}}
 elif q['method']=='tools/call' and q['params']['name']=='heard':
  result={'content':[{'type':'text','text':'nothing heard fits'}], '_meta':{'jam':{'name':'test-reader','place':'local-test','joinedRank':0}}}
 else:
  result={'content':[{'type':'text','text':'!{(kept "λ")}\\nsecond line'},{'type':'image','mimeType':'image/png','data':'fixture'}], 'received':q['params'], 'initialized':initialized}
 print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':result}),flush=True)
""")
            backend.chmod(0o755)
            runner = """import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('bridge',sys.argv[1])
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.PLUGIN=pathlib.Path(sys.argv[2]);m.run_mcp([])
"""
            env = dict(os.environ, JAM_NAME="test-reader", JAM_CODEX_PUSH="1",
                       JAM_CODEX_STATE=str(root / "state"), JAM_CODEX_SOCKET=str(root / "absent.sock"))
            env.pop("JAM_CODEX_THREAD", None)
            process = subprocess.Popen([sys.executable, "-c", runner, str(SOURCE), str(root)],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True, env=env)
            params = {"name": "tell", "arguments": {"value": "!{(kept \"λ\")}"},
                      "_meta": {"threadId": THREAD}}

            def line(stream):
                self.assertTrue(select.select([stream], [], [], 5)[0], "fixture output timed out")
                return stream.readline()

            try:
                process.stdin.write(json.dumps({"id": 1, "method": "initialize", "params": {}}) + "\n")
                process.stdin.flush()
                initialized = json.loads(line(process.stdout))
                self.assertEqual(initialized["id"], 1)
                process.stdin.write(json.dumps({"method": "notifications/initialized", "params": {}}) + "\n")
                process.stdin.write(json.dumps({"id": 2, "method": "tools/call", "params": params}) + "\n")
                process.stdin.flush()
                answer = json.loads(line(process.stdout))
                self.assertEqual(answer["id"], 2)
                self.assertTrue(answer["result"]["initialized"])
                self.assertEqual(answer["result"]["received"], params)
                self.assertEqual(answer["result"]["content"], [
                    {"type": "text", "text": '!{(kept "λ")}\nsecond line'},
                    {"type": "image", "mimeType": "image/png", "data": "fixture"},
                ])
                warning = line(process.stderr)
                self.assertIn("no shared Codex app-server socket", warning)
                self.assertIn("tools remain available", warning)
                process.stdin.write(json.dumps({"id": 3, "method": "tools/call", "params": params}) + "\n")
                process.stdin.flush()
                after_failure = json.loads(line(process.stdout))
                self.assertEqual(after_failure["id"], 3)
                self.assertEqual(after_failure["result"], answer["result"])
                process.stdin.close()
                process.stdin = None
                process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()


if __name__ == "__main__":
    unittest.main()
