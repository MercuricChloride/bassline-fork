"""JSON RPC over the Codex app-server's Unix WebSocket transport."""

from __future__ import annotations

import concurrent.futures
import json
import threading

from websockets.sync.client import unix_connect


class SocketError(Exception):
    """The local app-server connection refused or ended."""


class SocketRpc:
    """One WebSocket reader, independent callers, and explicit server requests.

    A request from the app-server is handed to ``request`` without deciding it.
    In particular this connection never grants an approval on the user's behalf.
    """

    def __init__(self, path, notification=None, request=None):
        self.socket = unix_connect(str(path), compression=None, open_timeout=5,
                                   close_timeout=2, max_size=None)
        self.socket.__enter__()
        self.notification = notification or (lambda message: None)
        self.server_request = request or (lambda message: None)
        self.pending = {}
        self.lock = threading.Lock()
        self.writing = threading.Lock()
        self.sequence = 0
        self.closed = False
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def send(self, message):
        with self.writing:
            if self.closed:
                raise SocketError("the local Codex connection has ended")
            try:
                self.socket.send(json.dumps(message, ensure_ascii=False))
            except Exception as error:
                raise SocketError("the local Codex connection has ended") from error

    def request(self, method, params):
        future = concurrent.futures.Future()
        with self.lock:
            if self.closed:
                future.set_exception(SocketError("the local Codex connection has ended"))
                return future
            self.sequence += 1
            identifier = f"jam-adapter:{self.sequence}"
            self.pending[identifier] = future
            future.rpc_id = identifier
        try:
            self.send({"id": identifier, "method": method, "params": params})
        except Exception as error:
            with self.lock:
                self.pending.pop(identifier, None)
            if not future.done():
                future.set_exception(error)
        return future

    def call(self, method, params, timeout=35):
        future = self.request(method, params)
        try:
            return future.result(timeout)
        except concurrent.futures.TimeoutError:
            with self.lock:
                self.pending.pop(future.rpc_id, None)
            raise SocketError("the local Codex host did not confirm carriage in time") from None

    def _read(self):
        error = SocketError("the local Codex connection has ended")
        try:
            for frame in self.socket:
                if not isinstance(frame, str):
                    raise SocketError("Codex sent a binary frame where a JSON text frame was required")
                message = json.loads(frame)
                if not isinstance(message, dict):
                    raise SocketError("Codex sent something other than an RPC object")
                # Server requests are not replies, even if an ID happens to
                # match one of ours. Their decisions belong to the client UI.
                if "method" in message:
                    if "id" in message:
                        self.server_request(message)
                    else:
                        self.notification(message)
                    continue
                with self.lock:
                    future = self.pending.pop(message.get("id"), None)
                if future is None or future.done():
                    continue
                if "error" in message:
                    future.set_exception(SocketError(json.dumps(message["error"], ensure_ascii=False)))
                else:
                    future.set_result(message.get("result", {}))
        except Exception as failure:
            error = failure
        finally:
            with self.lock:
                self.closed = True
                pending, self.pending = self.pending, {}
            for future in pending.values():
                if not future.done():
                    future.set_exception(error)
            self.socket.close()

    def close(self):
        self.socket.close()
        if threading.current_thread() is not self.reader:
            self.reader.join(timeout=3)
