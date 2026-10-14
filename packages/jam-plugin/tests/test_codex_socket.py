"""Actual Unix WebSocket framing, plus opt-in isolated Codex runtime checks."""

import concurrent.futures
from contextlib import ExitStack, contextmanager
import http.server
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from codex_socket import SocketError, SocketRpc
from websockets.sync.server import unix_serve


@contextmanager
def local_server(handler):
    # A short path also works within macOS's Unix socket path limit.
    with tempfile.TemporaryDirectory(prefix="jam-ws-", dir="/tmp") as root:
        path = str(Path(root) / "rpc.sock")
        with unix_serve(handler, path, compression=None) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                yield path
            finally:
                server.shutdown()
                thread.join(timeout=3)


class SocketTests(unittest.TestCase):
    def test_independent_text_frames_out_of_order_and_complete_unicode(self):
        payload = "héard 🌊\n" * 150000

        def handler(socket):
            first = json.loads(socket.recv())
            second = json.loads(socket.recv())
            socket.send(json.dumps({"id": second["id"], "result": {"output": payload}}))
            socket.send(json.dumps({"id": first["id"], "result": first["params"]}))
            socket.recv()

        with local_server(handler) as path:
            rpc = SocketRpc(path)
            self.addCleanup(rpc.close)
            first = rpc.request("first", {"line": "a\nb"})
            second = rpc.request("second", {})
            self.assertEqual(second.result(3), {"output": payload})
            self.assertEqual(first.result(3), {"line": "a\nb"})
            rpc.send({"method": "done", "params": {}})

    def test_server_request_is_surfaced_without_automatic_decision(self):
        requests, notices, wire = [], [], []
        received = threading.Event()

        def handler(socket):
            query = json.loads(socket.recv())
            socket.send(json.dumps({"id": query["id"], "method": "item/commandExecution/requestApproval",
                                    "params": {"command": "fixture"}}))
            socket.send(json.dumps({"method": "turn/started", "params": {}}))
            socket.send(json.dumps({"id": query["id"], "result": {"accepted": True}}))
            try:
                wire.append(socket.recv(timeout=.2))
            except TimeoutError:
                pass
            received.set()

        with local_server(handler) as path:
            rpc = SocketRpc(path, notification=notices.append, request=requests.append)
            self.addCleanup(rpc.close)
            self.assertEqual(rpc.call("turn/start", {}, timeout=3), {"accepted": True})
            self.assertTrue(received.wait(3))
            self.assertEqual(len(requests), 1)
            self.assertEqual(notices[0]["method"], "turn/started")
            self.assertEqual(wire, [])

    def test_host_refusal_and_disconnection_fail_callers(self):
        def handler(socket):
            query = json.loads(socket.recv())
            socket.send(json.dumps({"id": query["id"], "error": {"code": -1, "message": "fixture refusal"}}))
            socket.recv()

        with local_server(handler) as path:
            rpc = SocketRpc(path)
            self.addCleanup(rpc.close)
            with self.assertRaisesRegex(SocketError, "fixture refusal"):
                rpc.call("refused", {}, timeout=3)
            with self.assertRaises(SocketError):
                rpc.call("ended", {}, timeout=3)
            self.assertTrue(rpc.closed)

    def test_late_response_after_timeout_does_not_end_connection(self):
        def handler(socket):
            first = json.loads(socket.recv())
            second = json.loads(socket.recv())
            socket.send(json.dumps({"id": first["id"], "result": {}}))
            socket.send(json.dumps({"id": second["id"], "result": {"still": "available"}}))
            socket.recv()

        with local_server(handler) as path:
            rpc = SocketRpc(path)
            self.addCleanup(rpc.close)
            with self.assertRaisesRegex(SocketError, "in time"):
                rpc.call("late", {}, timeout=.02)
            self.assertEqual(rpc.call("next", {}, timeout=3), {"still": "available"})
            self.assertFalse(rpc.closed)
            rpc.send({"method": "done", "params": {}})

    def test_binary_frame_is_refused(self):
        def handler(socket):
            socket.recv()
            socket.send(b'{"result":{}}')

        with local_server(handler) as path:
            rpc = SocketRpc(path)
            self.addCleanup(rpc.close)
            with self.assertRaisesRegex(SocketError, "binary frame"):
                rpc.call("query", {}, timeout=3)


class FakeModel:
    """A loopback Responses SSE fixture; it never contacts another model."""

    def __init__(self):
        self.requests = []
        self.lock = threading.Lock()
        self.actions = []
        self.started = threading.Event()
        self.release = threading.Event()
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                with fixture.lock:
                    fixture.requests.append(json.loads(raw))
                    number = len(fixture.requests)
                    action = fixture.actions.pop(0) if fixture.actions else "assistant"
                if action == "block":
                    fixture.started.set()
                    fixture.release.wait(15)
                    action = "assistant"
                if action == "approval":
                    item = {"id": f"fc_{number}", "type": "function_call", "call_id": f"call_{number}",
                            "name": "exec_command", "namespace": "functions",
                            "arguments": json.dumps({"cmd": "true", "sandbox_permissions": "require_escalated",
                                                       "justification": "Isolated test fixture approval"})}
                else:
                    item = {"id": f"msg_{number}", "type": "message", "role": "assistant",
                            "status": "completed", "content": [{"type": "output_text", "text": "fixture response", "annotations": []}]}
                response = {"id": f"resp_{number}", "object": "response", "created_at": 0,
                            "status": "completed", "output": [item],
                            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                events = [("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item}),
                          ("response.completed", {"type": "response.completed", "response": response})]
                for name, value in events:
                    self.wfile.write(f"event: {name}\ndata: {json.dumps(value)}\n\n".encode())
                    self.wfile.flush()

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(3)


class Events:
    def __init__(self):
        self.values = []
        self.condition = threading.Condition()

    def add(self, value):
        with self.condition:
            self.values.append(value)
            self.condition.notify_all()

    def wait(self, predicate, timeout=15):
        end = time.monotonic() + timeout
        with self.condition:
            while True:
                for value in self.values:
                    if predicate(value):
                        return value
                remaining = end - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f"No matching event; saw {[v.get('method') for v in self.values]}")
                self.condition.wait(remaining)


@contextmanager
def isolated_daemon(binary):
    """No global Codex home, login, current conversation, or external model."""
    with tempfile.TemporaryDirectory(prefix="jam-codex-", dir="/tmp") as root:
        model = FakeModel()
        environment = dict(os.environ, CODEX_HOME=root)
        # An isolated runtime must not inherit a real conversation's identity.
        environment.pop("CODEX_THREAD_ID", None)
        environment.pop("CODEX_SESSION_ID", None)
        config = ('model = "fake-fixture"\nmodel_provider = "fixture"\n'
                  '[model_providers.fixture]\nname = "Fixture"\n'
                  f'base_url = "http://127.0.0.1:{model.server.server_port}/v1"\n'
                  'wire_api = "responses"\nrequires_openai_auth = false\n'
                  'supports_websockets = false\nrequest_max_retries = 0\nstream_max_retries = 0\n')
        Path(root, "config.toml").write_text(config)
        try:
            started = subprocess.run([binary, "app-server", "daemon", "start"], env=environment,
                                     cwd=root, text=True, capture_output=True, timeout=20)
            if started.returncode:
                raise AssertionError(f"Isolated daemon failed: {started.stderr}")
            path = Path(root, "app-server-control", "app-server-control.sock")
            deadline = time.monotonic() + 10
            while not path.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            yield root, path, model, environment
        finally:
            subprocess.run([binary, "app-server", "daemon", "stop"], env=environment,
                           cwd=root, text=True, capture_output=True, timeout=20)
            model.close()


def initialized(path, events):
    rpc = SocketRpc(path, notification=events.add, request=events.add)
    rpc.call("initialize", {"clientInfo": {"name": "isolated_jam_test", "version": "1"},
                            "capabilities": {"experimentalApi": True}})
    rpc.send({"method": "initialized", "params": {}})
    return rpc


def completed(events, turn):
    value = events.wait(lambda v: v.get("method") == "turn/completed"
                        and v.get("params", {}).get("turn", {}).get("id") == turn)
    if value["params"]["turn"]["status"] != "completed":
        raise AssertionError(value)


@unittest.skipUnless(os.environ.get("JAM_CODEX_TEST_BINARY"), "Set JAM_CODEX_TEST_BINARY for an isolated local runtime test")
class CodexRuntimeTests(unittest.TestCase):
    def test_real_daemon_idle_wake_and_active_tool_output_preserved(self):
        binary = os.environ["JAM_CODEX_TEST_BINARY"]
        with isolated_daemon(binary) as (root, path, model, environment), ExitStack() as clients:
            events = Events()
            rpc = initialized(path, events)
            clients.callback(rpc.close)
            thread = rpc.call("thread/start", {"cwd": root, "approvalPolicy": "never", "sandbox": "read-only"})["thread"]["id"]
            normal = rpc.call("turn/start", {"threadId": thread, "input": [{"type": "text", "text": "initial fixture"}]})["turn"]["id"]
            completed(events, normal)
            output = '(heard (for fixture) 7 {digest: "fixture" to-you: ![]} !{(said "full 🌊\\nvalue")})'
            idle = rpc.call("turn/start", {"threadId": thread, "input": [], "toolOutput": {"namespace": "jam", "name": "heard", "output": output}})["turn"]["id"]
            completed(events, idle)
            model.actions.append("block")
            active = rpc.call("turn/start", {"threadId": thread, "input": [{"type": "text", "text": "active fixture"}]})["turn"]["id"]
            self.assertTrue(model.started.wait(10))
            queued = rpc.call("turn/start", {"threadId": thread, "input": [], "toolOutput": {"namespace": "jam", "name": "heard", "output": output}})["turn"]["id"]
            self.assertEqual(queued, active)
            model.release.set()
            completed(events, active)
            carried = [item for request in model.requests for item in request.get("input", [])
                       if item.get("type") == "function_call_output" and item.get("output") == output]
            self.assertGreaterEqual(len(carried), 2)
            self.assertTrue(all(item.get("name") == "heard" and item.get("namespace") == "jam" for item in carried))
            rpc.close()

    def test_wake_turn_approval_reaches_subscribing_ui_only(self):
        binary = os.environ["JAM_CODEX_TEST_BINARY"]
        with isolated_daemon(binary) as (root, path, model, environment), ExitStack() as clients:
            ui_events, wake_events = Events(), Events()
            ui, wake = initialized(path, ui_events), initialized(path, wake_events)
            clients.callback(ui.close)
            clients.callback(wake.close)
            thread = ui.call("thread/start", {"cwd": root, "approvalPolicy": "on-request", "sandbox": "read-only"})["thread"]["id"]
            turn = ui.call("turn/start", {"threadId": thread, "input": [{"type": "text", "text": "initial fixture"}]})["turn"]["id"]
            completed(ui_events, turn)
            model.actions.append("approval")
            turn = wake.call("turn/start", {"threadId": thread, "input": [], "toolOutput": {"namespace": "jam", "name": "heard", "output": "isolated approval probe"}})["turn"]["id"]
            requested = lambda v: v.get("method") == "item/commandExecution/requestApproval" and "id" in v
            ui_request = ui_events.wait(requested)
            self.assertEqual(ui_request["params"]["threadId"], thread)
            self.assertFalse(any(requested(value) for value in wake_events.values))
            self.assertEqual(wake.call("thread/unsubscribe", {"threadId": thread}), {"status": "notSubscribed"})
            # The fixture request remains unanswered: no execution is approved.
            self.assertFalse(any(v.get("method") == "turn/completed" and v.get("params", {}).get("turn", {}).get("id") == turn
                                 for v in wake_events.values))
            ui.call("turn/interrupt", {"threadId": thread, "turnId": turn})
            ui_events.wait(lambda value: value.get("method") == "turn/completed"
                           and value.get("params", {}).get("turn", {}).get("id") == turn)
            wake.close()
            ui.close()

    def test_complete_mcp_bridge_wakes_idle_thread_and_saves_acceptance(self):
        import codex_bridge as bridge

        binary = os.environ["JAM_CODEX_TEST_BINARY"]
        plugin = Path(__file__).resolve().parents[1]
        jam_binary = plugin.parent / "blcli" / "bin" / "bl-jam"
        self.assertTrue(jam_binary.is_file(), "Build bl-jam before this isolated integration test")
        with isolated_daemon(binary) as (root, path, model, environment), ExitStack() as clients:
            events = Events()
            ui = initialized(path, events)
            clients.callback(ui.close)
            thread = ui.call("thread/start", {"cwd": root, "approvalPolicy": "never", "sandbox": "read-only"})["thread"]["id"]
            initial = ui.call("turn/start", {"threadId": thread, "input": [{"type": "text", "text": "initial fixture"}]})["turn"]["id"]
            completed(events, initial)
            jam = subprocess.Popen([str(jam_binary), "serve", "--memory", "127.0.0.1:0"],
                                   cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding="utf-8")

            def stop_jam():
                jam.terminate()
                try:
                    jam.wait(3)
                except subprocess.TimeoutExpired:
                    jam.kill()
                    jam.wait(3)
                jam.stdout.close()
                jam.stderr.close()

            clients.callback(stop_jam)
            self.assertTrue(select.select([jam.stderr], [], [], 5)[0], "The isolated jam did not start")
            listening = jam.stderr.readline().strip()
            self.assertTrue(listening.startswith("-- listening on "), listening)
            place = listening.removeprefix("-- listening on ").split(",")[0]
            name = "isolated-codex-fixture"
            state = str(Path(root) / "delivery")
            bridge_environment = dict(environment, JAM_CODEX_SOCKET=str(path), JAM_CODEX_STATE=state,
                                      JAM_CODEX_PUSH="1", JAM_NAME=name)
            bridge_environment.pop("JAM_CODEX_THREAD", None)
            bridge_environment.pop("JAM_CODEX_REPLAY", None)
            # These variables exist only while spawning this fixture subprocess.
            with patch.dict(os.environ, bridge_environment, clear=True):
                proxy = bridge.Rpc([sys.executable, str(plugin / "scripts" / "codex_bridge.py"),
                                    "--mcp", "--at", place, "--as", name])
            clients.callback(proxy.close)
            proxy.call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                       "clientInfo": {"name": "fixture", "version": "1"}})
            proxy.send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
            first_read = proxy.call("tools/call", {"name": "heard", "arguments": {"last": 0},
                                                   "_meta": {"threadId": thread}})
            self.assertEqual(first_read["_meta"]["jam"]["name"], name)
            self.assertEqual(first_read["_meta"]["jam"]["place"], place)
            deadline = time.monotonic() + 15
            snapshots = []
            while time.monotonic() < deadline:
                snapshots = list(Path(state, thread).glob("*.blb"))
                if snapshots:
                    break
                time.sleep(.05)
            self.assertEqual(len(snapshots), 1, "The actual bridge did not bind and save its attachment floor")
            before = bridge.decode(snapshots[0].read_bytes())
            self.assertGreaterEqual(before.fields[2].value, 0)
            self.assertEqual(before.fields[2], before.fields[3])
            answer = bridge.Set([
                bridge.rec(bridge.sym.by, bridge.sym.fixture_sender),
                bridge.rec(bridge.sym.said, bridge.Text("complete 🌊\nmarked payload")),
                bridge.rec(bridge.sym("for"), bridge.sym(name)),
                bridge.rec(bridge.sym.integer, bridge.Integer(10**80)),
            ], mark=True)
            host, port = place.rsplit(":", 1)
            with socket.create_connection((host, int(port)), timeout=3) as connection:
                connection.sendall(bridge.encode(bridge.rec(bridge.sym.general, answer)))
            delivery = events.wait(lambda value: value.get("method") == "item/completed"
                                   and value.get("params", {}).get("item", {}).get("type") == "functionCallOutput")
            item = delivery["params"]["item"]
            self.assertEqual((item["namespace"], item["name"]), ("jam", "heard"))
            carried = bridge.parse_records({"content": [{"type": "text", "text": item["output"]}]})
            self.assertEqual(len(carried), 1)
            self.assertEqual(bridge.encode(carried[0].fields[3]), bridge.encode(answer))
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                saved = bridge.decode(snapshots[0].read_bytes())
                entries = list(saved.fields[4])
                if entries and all(entry.head == bridge.sym.accepted for entry in entries):
                    break
                time.sleep(.05)
            self.assertEqual(entries, [bridge.rec(bridge.sym.accepted, *bridge.heard_key(carried[0]))])
            self.assertGreater(saved.fields[3].value, before.fields[3].value)
            completed(events, delivery["params"]["turnId"])
            landed = [part for request in model.requests for part in request.get("input", [])
                      if part.get("type") == "function_call_output" and part.get("output") == item["output"]]
            self.assertEqual(len(landed), 1)


if __name__ == "__main__":
    unittest.main()
