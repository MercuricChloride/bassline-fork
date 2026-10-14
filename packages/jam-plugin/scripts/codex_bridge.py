#!/usr/bin/env python3
"""Jam's MCP tools, with an optional local Codex app-server wake adapter.

The adapter carries complete heard values as tool output. Its own delivery
reading is kept locally in CE, independently of who the jam says was here.
It never treats a queued prompt, a connection, or a successful turn as an
answer to anything said on the jam.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid

PLUGIN = Path(__file__).resolve().parents[1]
PYTHON_VALUES = PLUGIN.parent / "blpy" / "src"
if PYTHON_VALUES.is_dir():
    sys.path.insert(0, str(PYTHON_VALUES))

from bassline import Dict, Integer, Record, Set, Text, decode, encode, read_all, rec, sym, to_text

SHAPE = "(shape (heard q r {to-you: w}) {q r w})"


class BridgeError(Exception):
    """A local reading or carriage that could not be taken."""


class RanksRestarted(BridgeError):
    """The jam no longer extends the ranks this reader has kept."""


def thread_id(value):
    if not isinstance(value, str):
        raise BridgeError("the wake target must be a Codex thread UUID")
    try:
        uuid.UUID(value)
    except ValueError as error:
        raise BridgeError("the wake target must be a Codex thread UUID") from error
    return value


def heard_key(value):
    if (not isinstance(value, Record) or value.mark or value.head != sym.heard
            or len(value.fields) != 4):
        raise BridgeError("expected one complete (heard Q R READINGS A) value")
    q, rank, readings, _ = value.fields
    if not isinstance(rank, Integer) or rank.mark or rank.value < 0:
        raise BridgeError("a heard rank must be an unmarked nonnegative integer")
    if not isinstance(readings, Dict) or readings.mark or sym.digest not in readings:
        raise BridgeError("a heard reading must carry its digest")
    return q, readings[sym.digest]


def parse_records(result):
    if result.get("isError"):
        raise BridgeError(str(result.get("content", "jam refused the reading")))
    contents = result.get("content", [])
    if any(part.get("type") != "text" for part in contents):
        raise BridgeError("heard returned something other than text values")
    text = "\n".join(part["text"] for part in contents)
    if text == "nothing heard fits":
        return []
    values = list(read_all(text))
    for value in values:
        heard_key(value)
    return sorted(values, key=lambda value: value.fields[1].value)


class Rpc:
    """The backend's JSONL MCP connection; one reader, independent callers."""

    def __init__(self, argv, notification=None):
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=sys.stderr,
                                        text=True, encoding="utf-8", bufsize=1)
        self.notification = notification or (lambda message: None)
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
                raise BridgeError("the local pipe has ended")
            try:
                self.process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
                self.process.stdin.flush()
            except (BrokenPipeError, OSError) as error:
                raise BridgeError("the local pipe has ended") from error

    def request(self, method, params):
        future = concurrent.futures.Future()
        with self.lock:
            self.sequence += 1
            identifier = f"jam-adapter:{self.sequence}"
            self.pending[identifier] = future
            future.rpc_id = identifier
        try:
            self.send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
        except Exception as error:
            with self.lock:
                self.pending.pop(identifier, None)
            future.set_exception(error)
        return future

    def call(self, method, params, timeout=35):
        future = self.request(method, params)
        try:
            return future.result(timeout)
        except concurrent.futures.TimeoutError:
            with self.lock:
                self.pending.pop(future.rpc_id, None)
            raise BridgeError("the local host did not confirm carriage in time") from None

    def _read(self):
        error = BridgeError("the local pipe has ended")
        try:
            for line in self.process.stdout:
                message = json.loads(line)
                if "id" not in message:
                    self.notification(message)
                    continue
                with self.lock:
                    future = self.pending.pop(message["id"], None)
                if future is None:
                    continue
                if "error" in message:
                    future.set_exception(BridgeError(json.dumps(message["error"])))
                else:
                    future.set_result(message.get("result", {}))
        except Exception as failure:
            error = failure
        finally:
            self.closed = True
            with self.lock:
                pending, self.pending = self.pending, {}
            for future in pending.values():
                future.set_exception(error)

    def close(self):
        with self.writing:
            if self.process.stdin and not self.process.stdin.closed:
                self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=2)
        self.process.stdout.close()


class Inbox:
    """A local delivery reading, saved whole before its cursor advances."""

    def __init__(self, root, thread, name, place):
        thread_id(thread)
        self.name, self.place = name, place
        scope = hashlib.sha256((name + "\0" + place).encode()).hexdigest()
        directory = Path(root) / thread
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = directory / f"{scope}.blb"
        self.lock_file = open(directory / f"{scope}.lock", "a+b")
        os.chmod(self.lock_file.name, 0o600)
        try:
            fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self.lock_file.close()
            raise BridgeError("another jam adapter is already delivering to this thread") from error
        self.cursor = None
        self.floor = None
        self.waiting = {}
        self.accepted = set()
        try:
            if self.path.exists():
                self._load(decode(self.path.read_bytes()))
        except Exception:
            self.close()
            raise

    def _load(self, value):
        if (not isinstance(value, Record) or value.mark or value.head != sym.delivery
                or len(value.fields) != 5):
            raise BridgeError("the delivery file is not a delivery reading")
        name, place, floor, cursor, entries = value.fields
        if name != Text(self.name) or place != Text(self.place):
            raise BridgeError("the delivery file belongs to another local reading")
        if (not isinstance(floor, Integer) or floor.mark or floor.value < -1
                or not isinstance(cursor, Integer) or cursor.mark or cursor.value < floor.value
                or not isinstance(entries, Set) or entries.mark):
            raise BridgeError("the delivery reading has an invalid cursor or entries")
        self.cursor = cursor.value
        self.floor = floor.value
        for entry in entries:
            if not isinstance(entry, Record) or entry.mark:
                raise BridgeError("the delivery reading has an invalid entry")
            if entry.head == sym.pending and len(entry.fields) == 1:
                record = entry.fields[0]
                self.waiting[heard_key(record)] = record
            elif entry.head == sym.accepted and len(entry.fields) == 2:
                self.accepted.add(tuple(entry.fields))
            else:
                raise BridgeError("the delivery reading has an unknown entry")
        if self.accepted.intersection(self.waiting):
            raise BridgeError("a delivery is both pending and accepted")

    @property
    def pending(self):
        return sorted(self.waiting.values(), key=lambda value: value.fields[1].value)

    def _save(self):
        value = rec(sym.delivery, Text(self.name), Text(self.place), Integer(self.floor), Integer(self.cursor),
                    Set([rec(sym.pending, value) for value in self.waiting.values()]
                        + [rec(sym.accepted, q, digest) for q, digest in self.accepted]))
        descriptor, temporary = tempfile.mkstemp(prefix=".delivery-", dir=self.path.parent)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(encode(value))
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def initialize(self, rank):
        if self.cursor is None:
            self.cursor = self.floor = rank
            try:
                self._save()
            except Exception:
                self.cursor = self.floor = None
                raise

    def offer(self, records):
        previous = self.cursor, self.waiting.copy()
        try:
            for value in records:
                key = heard_key(value)
                if key not in self.accepted:
                    self.waiting.setdefault(key, value)
                self.cursor = max(self.cursor, value.fields[1].value)
            if previous != (self.cursor, self.waiting):
                self._save()
        except Exception:
            self.cursor, self.waiting = previous
            raise

    def accept(self, records):
        previous = self.waiting.copy(), self.accepted.copy()
        try:
            for value in records:
                key = heard_key(value)
                self.accepted.add(key)
                self.waiting.pop(key, None)
            self._save()
        except Exception:
            self.waiting, self.accepted = previous
            raise

    def close(self):
        if not self.lock_file.closed:
            self.lock_file.close()


class Binding:
    """The foreign host names its thread; shell ancestry never chooses it."""

    def __init__(self, explicit=None):
        self.thread = thread_id(explicit) if explicit else None
        self.ready = threading.Event()
        if self.thread:
            self.ready.set()

    def observe(self, params):
        candidate = params.get("_meta", {}).get("threadId")
        if candidate is None:
            return
        candidate = thread_id(candidate)
        if self.thread is not None and candidate != self.thread:
            raise BridgeError("one jam adapter cannot wake two different Codex threads")
        self.thread = candidate
        self.ready.set()


class Wake:
    def __init__(self, backend, host, inbox, thread, batch_size=50, joined_rank=None):
        self.backend, self.host = backend, host
        self.inbox, self.thread = inbox, thread_id(thread)
        self.batch_size = batch_size
        self.scan_since = inbox.floor
        self.round_done = False
        self.joined_rank = joined_rank

    def poll_once(self, wait=5):
        arguments = {"shape": SHAPE, "since": self.scan_since,
                     "first": self.batch_size, "wait": wait}
        result = self.backend.call("tools/call", {"name": "heard", "arguments": arguments},
                                   timeout=wait + 5)
        records = parse_records(result)
        joined = result.get("_meta", {}).get("jam", {}).get("joinedRank")
        if joined is not None:
            if type(joined) is not int or joined < -1:
                raise BridgeError("jam returned an invalid joined rank")
            if joined >= 0 and joined != self.joined_rank:
                if self.joined_rank is not None and joined < self.inbox.cursor:
                    raise RanksRestarted(f"jam ranks restarted below this reader's saved rank; "
                                         f"move {self.inbox.path} aside before a fresh attachment")
                self.joined_rank = joined
        if records:
            self.inbox.offer(records)
        self.round_done = len(records) < self.batch_size
        # Eligibility is this reader's current understanding. More rooms or
        # earlier speech may make an older answer fit on a later reading.
        self.scan_since = (self.inbox.floor if self.round_done
                           else records[-1].fields[1].value)
        return records

    def deliver_once(self):
        records = self.inbox.pending[:self.batch_size]
        if not records:
            return []
        output = "\n".join(to_text(value) for value in records)
        self.host.call("turn/start", {"threadId": self.thread, "input": [],
                       "toolOutput": {"name": "heard", "namespace": "jam", "output": output}})
        self.inbox.accept(records)
        return records


def control_socket():
    if os.environ.get("JAM_CODEX_SOCKET"):
        return Path(os.environ["JAM_CODEX_SOCKET"]).expanduser().resolve()
    home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    return home / "app-server-control" / "app-server-control.sock"


def launch_alive():
    """A local wake decision: the launcher holds this lock while its UI runs."""
    path = os.environ.get("JAM_CODEX_LEASE")
    if not path:
        return True
    try:
        with open(path, "rb") as lease:
            try:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            return False
    except OSError:
        return False


def run_mcp(arguments):
    writing = threading.Lock()

    def emit(message):
        with writing:
            sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    backend = Rpc([str(PLUGIN / "bin" / "jam-mcp"), *arguments, "--push", "none"], emit)
    binding = Binding(os.environ.get("JAM_CODEX_THREAD"))
    stopped = threading.Event()
    initialized = threading.Event()
    last_warning = None

    def warn(error):
        nonlocal last_warning
        message = str(error)
        if message != last_warning:
            print(f"-- jam Codex wake: {message}; tools remain available", file=sys.stderr)
            last_warning = message

    def host_request(message):
        warn(f"Codex requested {message.get('method', 'user input')}; "
             "respond in the attached Codex client")

    def worker():
        host = inbox = wake = None
        try:
            while not stopped.is_set() and launch_alive() and not initialized.wait(0.2):
                pass
            if stopped.is_set() or not launch_alive():
                return
            # The echoed here is a barrier for the initial asks. A last:1
            # snapshot alone cannot say that their history has all been heard.
            while not stopped.is_set() and launch_alive():
                try:
                    result = backend.call("tools/call", {
                        "name": "heard", "arguments": {"last": 0}})
                    parse_records(result)
                    local = result.get("_meta", {}).get("jam", {})
                    baseline = local.get("joinedRank", -1)
                    if type(baseline) is not int or baseline < -1:
                        raise BridgeError("jam returned an invalid joined rank")
                    if baseline >= 0:
                        name, place = local["name"], local["place"]
                        if not isinstance(name, str) or not isinstance(place, str):
                            raise BridgeError("jam returned an invalid local name or place")
                        break
                    warn("waiting for the jam's initial answers")
                except Exception as error:
                    warn(error)
                stopped.wait(2)
            while not stopped.is_set() and launch_alive() and not binding.ready.wait(0.2):
                pass
            if stopped.is_set() or not launch_alive():
                return
            root = os.environ.get("JAM_CODEX_STATE", str(Path.home() / ".bl" / "codex"))
            inbox = Inbox(root, binding.thread, name, place)
            if inbox.cursor is not None and baseline < inbox.cursor:
                raise RanksRestarted(f"jam ranks restarted below this reader's saved rank; "
                                     f"move {inbox.path} aside before a fresh attachment")
            inbox.initialize(-1 if os.environ.get("JAM_CODEX_REPLAY") == "1" else baseline)
            wake = Wake(backend, None, inbox, binding.thread, joined_rank=baseline)
            while not stopped.is_set() and launch_alive():
                try:
                    if host is None or host.closed:
                        if host is not None:
                            host.close()
                        socket = control_socket()
                        if not socket.exists():
                            raise BridgeError("no shared Codex app-server socket; use codex-jam on its daemon")
                        # The daemon's Unix socket speaks WebSocket, including
                        # its HTTP upgrade, rather than MCP's JSONL stdio.
                        from codex_socket import SocketRpc
                        connected = SocketRpc(socket, request=host_request)
                        try:
                            connected.call("initialize", {"clientInfo": {"name": "bassline_jam",
                                           "title": "Bassline jam", "version": "0.1.0"},
                                           "capabilities": {"experimentalApi": True}})
                            connected.send({"method": "initialized", "params": {}})
                        except Exception:
                            connected.close()
                            raise
                        host = connected
                        wake.host = host
                    wake.deliver_once()
                    wake.poll_once()
                    if wake.round_done:
                        stopped.wait(2)
                except RanksRestarted:
                    raise
                except Exception as error:
                    warn(error)
                    # Still collect arrivals when the host cannot take them.
                    try:
                        wake.poll_once()
                    except RanksRestarted:
                        raise
                    except Exception as reading_error:
                        warn(reading_error)
                    stopped.wait(2)
        except Exception as error:
            warn(error)
        finally:
            if host is not None:
                host.close()
            if inbox is not None:
                inbox.close()

    waking = threading.Thread(target=worker, daemon=True)
    waking.start()

    def forward(message):
        identifier, method = message["id"], message.get("method")
        params = message.get("params", {})
        future = backend.request(method, params)

        def complete(answer):
            try:
                result = answer.result()
                if method == "initialize":
                    result = dict(result)
                    result["instructions"] = result.get("instructions", "") + "\n\n" + (
                        "A local Codex wake adapter is enabled. Make one tell or heard call "
                        "to bind it to this thread. When the same shared Codex daemon is "
                        "available, new records said to you also arrive as jam heard tool "
                        "output, including while this thread is idle. This is carriage, "
                        "not an answer to what was said. Use heard for earlier history. "
                        "If the adapter cannot reach the host, the tools still work.")
                if method == "tools/call" and params.get("name") in ("tell", "heard") and not result.get("isError"):
                    try:
                        binding.observe(params)
                    except BridgeError as error:
                        stopped.set()
                        warn(error)
                emit({"jsonrpc": "2.0", "id": identifier, "result": result})
            except Exception as error:
                emit({"jsonrpc": "2.0", "id": identifier,
                      "error": {"code": -32603, "message": str(error)}})

        future.add_done_callback(complete)

    try:
        for line in sys.stdin:
            try:
                message = json.loads(line)
                if "id" in message:
                    forward(message)
                else:
                    backend.send(message)
                    if message.get("method") == "notifications/initialized":
                        initialized.set()
            except (ValueError, TypeError, KeyError) as error:
                emit({"jsonrpc": "2.0", "id": None,
                      "error": {"code": -32700, "message": str(error)}})
    finally:
        stopped.set()
        backend.close()
        waking.join(timeout=8)


def launch(name, arguments):
    if not name or name.startswith(".") or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in name):
        raise BridgeError("choose a jam name containing letters, digits, dots, hyphens or underscores")
    socket = control_socket()
    if not socket.exists():
        raise BridgeError("no shared Codex daemon; start it with codex app-server daemon start")
    executable = os.environ.get("JAM_CODEX_CODEX", "codex")
    wrapper = str(PLUGIN / "bin" / "jam-codex-mcp")
    options = {
        "mcp_servers.jam.command": "sh",
        "mcp_servers.jam.args": [wrapper],
        "mcp_servers.jam.cwd": str(PLUGIN),
        "mcp_servers.jam.tool_timeout_sec": 65,
        "mcp_servers.jam.env.JAM_NAME": name,
        "mcp_servers.jam.env.JAM_CODEX_PUSH": "1",
        "mcp_servers.jam.env.JAM_CODEX_SOCKET": str(socket),
        "mcp_servers.jam.env.JAM_CODEX_CODEX": shutil.which(executable) or executable,
        "mcp_servers.jam.env_vars": ["HOME", "PATH", "JAM_AT", "CODEX_HOME",
                                     "JAM_CODEX_STATE", "JAM_CODEX_REPLAY"],
    }
    # The daemon may have been started from a different shell. Give this
    # thread the launcher's settings rather than relying on its parent's env.
    for variable in ("HOME", "PATH", "JAM_AT", "CODEX_HOME", "JAM_CODEX_STATE", "JAM_CODEX_REPLAY", "JAM_CODEX_PYTHON"):
        if variable in os.environ:
            options["mcp_servers.jam.env." + variable] = os.environ[variable]
    # The remote TUI drops arbitrary -c options before thread/start and
    # thread/resume. Carry the jam definition in those per-thread requests.
    from codex_relay import launch as launch_tui
    instructions = (PLUGIN / "skills" / "jam" / "SKILL.md").read_text(encoding="utf-8")
    return launch_tui(executable, arguments, socket, options, instructions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mcp", action="store_true", help="proxy MCP stdio and wake its bound Codex thread")
    parser.add_argument("name", nargs="?", help="stable jam name for the Codex launcher")
    # MCP's foreign options belong to bl-jam, including their order and values.
    # Parsing them as launcher options can turn --at PLACE into a room name.
    arguments = sys.argv[1:]
    if arguments[:1] == ["--mcp"]:
        try:
            run_mcp(arguments[1:])
        except (BridgeError, OSError) as error:
            parser.exit(1, f"codex-jam: {error}\n")
        return
    try:
        if not arguments or arguments[0].startswith("-"):
            parser.parse_args(arguments)  # includes this entry's --help
            parser.error("give a jam name, or --mcp")
        name, remaining = arguments[0], arguments[1:]
        return launch(name, remaining[1:] if remaining[:1] == ["--"] else remaining)
    except (BridgeError, OSError) as error:
        parser.exit(1, f"codex-jam: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
