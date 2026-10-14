"""A launch-local WebSocket relay carrying jam config to the shared daemon.

The remote TUI forwards only selected configuration flags. Put the jam's MCP
definition in the actual per-thread request, without changing the daemon's
configuration on disk or deciding any of its requests for the UI.
"""

from __future__ import annotations

from copy import deepcopy
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading

from websockets.sync.client import unix_connect
from websockets.sync.server import unix_serve
from websockets.exceptions import ConnectionClosed


THREAD_METHODS = {"thread/start", "thread/resume", "thread/fork"}

# Ending the terminal hangs up the TUI, and a turn already running goes on in
# the shared daemon. So the relay notes which turns began on this launch's own
# connections, and when the launcher is told to stop it asks the daemon to
# interrupt exactly those. Noting never changes or delays a forwarded frame,
# and nothing here runs before a session has joined.
STOPPING = (signal.SIGTERM, signal.SIGHUP, signal.SIGALRM)
INTERRUPT_ID = "jam-relay-interrupt-"
_live = []
_live_lock = threading.Lock()
# Set first by the handler. A connection that ends after it is set interrupts
# its own turns as it goes, so whichever of the two gets there first has what
# it needs: the TUI is told to stop at the same moment the launcher is.
_stopping = threading.Event()
_asked_lock = threading.Lock()
_asked_count = 0


class Turns:
    """The turns one connection saw begin and not yet end, each with its thread.

    A turn is this launch's when it is on a thread this connection started,
    resumed, made by forking or began a turn on, whoever submitted the turn: the
    bridge's wake begins turns on the launch's thread from another
    connection. A turn heard of on any other thread is not noted.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.asked = {}
        self.threads = set()
        self.pending = set()
        self.running = {}
        self.interrupted = set()
        # Set while nothing is running and no turn/start awaits its answer:
        # a turn asked for and not yet named is as outstanding as one running.
        self.idle = threading.Event()
        self.idle.set()

    def _settle(self):
        """Call holding the lock: says whether anything is outstanding."""
        if self.running or self.asked:
            self.idle.clear()
        else:
            self.idle.set()

    def began(self, turn, thread):
        if isinstance(turn, str) and isinstance(thread, str):
            with self.lock:
                self.running[turn] = thread
                self._settle()

    def ended(self, turn):
        with self.lock:
            self.running.pop(turn, None)
            self._settle()

    def from_client(self, message):
        """A turn/start the TUI asks for: its answer names the turn. And which threads are this connection's."""
        method = message.get("method")
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        thread = params.get("threadId")
        with self.lock:
            # A fork's threadId names the thread it is forked from, which is
            # not this launch's by that alone: only the new thread its answer
            # names is.
            if method in ("thread/resume", "turn/start"):
                if isinstance(thread, str):
                    self.threads.add(thread)
            if method in THREAD_METHODS and "id" in message:
                self.pending.add(json.dumps(message["id"]))
            if method == "turn/start" and "id" in message:
                self.asked[json.dumps(message["id"])] = thread
                self._settle()

    def from_host(self, message):
        """What the daemon says of turns. Answers whether the frame is the relay's own, not the TUI's to see."""
        identifier = message.get("id")
        if isinstance(identifier, str) and identifier.startswith(INTERRUPT_ID):
            return True
        method, params = message.get("method"), message.get("params") or {}
        if method in ("turn/started", "turn/completed"):
            turn = params.get("turn") if isinstance(params.get("turn"), dict) else {}
            name = turn.get("id", params.get("turnId"))
            if method == "turn/started":
                thread = params.get("threadId", turn.get("threadId"))
                with self.lock:
                    own = thread in self.threads
                if own:
                    self.began(name, thread)
            else:
                self.ended(name)
        elif identifier is not None and method is None:
            key = json.dumps(identifier)
            result = message.get("result") if isinstance(message.get("result"), dict) else {}
            answered = result.get("turn") if isinstance(result.get("turn"), dict) else {}
            with self.lock:
                thread = self.asked.pop(key, None)
                # The turn its answer names is running from this same moment,
                # so nothing waiting sees a gap between asked and running.
                if isinstance(answered.get("id"), str) and isinstance(thread, str):
                    self.running[answered["id"]] = thread
                self._settle()
                if key in self.pending:
                    self.pending.discard(key)
                    made = result.get("thread") if isinstance(result.get("thread"), dict) else {}
                    for named in (made.get("id"), result.get("threadId")):
                        if isinstance(named, str):
                            self.threads.add(named)
            turn = result.get("turn")
            if isinstance(turn, dict):
                self.began(turn.get("id"), thread)
        return False


def interrupt_turns(host, turns):
    """Ask the daemon to interrupt the turns one connection saw running, each once. Answers whether any was asked. Never raises."""
    global _asked_count
    asked = False
    try:
        with turns.lock:
            running = {turn: thread for turn, thread in turns.running.items() if turn not in turns.interrupted}
            turns.interrupted.update(running)
        for turn, thread in running.items():
            try:
                with _asked_lock:
                    _asked_count += 1
                    number = _asked_count
                host.send(json.dumps({"id": INTERRUPT_ID + str(number), "method": "turn/interrupt",
                                      "params": {"threadId": thread, "turnId": turn}}))
                asked = True
            except Exception:
                pass
    except Exception:
        pass
    return asked


def interrupt_running(wait=2.0):
    """Ask the daemon to interrupt every turn this launch saw running, and wait at most `wait` in all. Never raises."""
    try:
        import time
        deadline = time.monotonic() + wait
        with _live_lock:
            live = list(_live)
        waiting = []
        for host, turns in live:
            asked = interrupt_turns(host, turns)
            with turns.lock:
                unanswered = bool(turns.asked)
            # A connection is waited on when a turn of its was asked for, or
            # when a turn/start is still unanswered: that turn is asked for by
            # the reader as soon as its answer names it. One whose asks all
            # failed to send has nothing coming and is not waited on.
            if asked or unanswered:
                waiting.append(turns)
        for turns in waiting:
            turns.idle.wait(max(0.0, deadline - time.monotonic()))
    except Exception:
        pass


def thread_request(message, jam_options, instructions=None):
    """Add only this launch's jam definition to a TUI thread request."""
    if message.get("method") not in THREAD_METHODS:
        return message
    result = deepcopy(message)
    params = result.setdefault("params", {})
    config = params.get("config")
    if config is None:
        config = {}
        params["config"] = config
    if not isinstance(config, dict):
        raise ValueError("the TUI's per-thread configuration must be an object")
    # Configuration accepts dotted keys. Replace this server as one whole
    # definition, retaining other servers and the TUI's own dynamic tools.
    definition = {}
    prefix = "mcp_servers.jam."
    for key, value in jam_options.items():
        if not key.startswith(prefix):
            raise ValueError("a jam launch option must describe mcp_servers.jam")
        parts = key[len(prefix):].split(".")
        destination = definition
        for part in parts[:-1]:
            destination = destination.setdefault(part, {})
        destination[parts[-1]] = deepcopy(value)
    for key in list(config):
        if key == "mcp_servers.jam" or key.startswith(prefix):
            del config[key]
    if isinstance(config.get("mcp_servers"), dict):
        config["mcp_servers"].pop("jam", None)
    config["mcp_servers.jam"] = definition
    if instructions:
        previous = params.get("developerInstructions")
        if previous is not None and not isinstance(previous, str):
            raise ValueError("the TUI's developer instructions must be text")
        params["developerInstructions"] = (previous + "\n\n" if previous else "") + instructions
    return result


def handler(upstream, jam_options, instructions=None, observer=None):
    """Each TUI connection retains its own upstream connection and approvals."""
    def connected(client):
        try:
            with unix_connect(str(upstream), compression=None, max_size=None) as host:
                turns = Turns()
                entry = (host, turns)
                with _live_lock:
                    _live.append(entry)

                def outward():
                    try:
                        for frame in host:
                            own = False
                            try:
                                if isinstance(frame, str):
                                    noted = json.loads(frame)
                                    own = isinstance(noted, dict) and turns.from_host(noted)
                                    # A turn that begins after stop was said is asked for as it is heard of.
                                    if _stopping.is_set():
                                        interrupt_turns(host, turns)
                            except Exception:
                                own = False
                            if not own:
                                try:
                                    client.send(frame)
                                except Exception:
                                    # The TUI has gone. Told to stop, keep
                                    # reading so a turn's completion is seen.
                                    if not _stopping.is_set():
                                        raise
                    except Exception:
                        pass
                    finally:
                        client.close()

                reader = threading.Thread(target=outward, daemon=True)
                reader.start()
                try:
                    for frame in client:
                        if not isinstance(frame, str):
                            raise ValueError("the TUI sent a binary RPC frame")
                        message = json.loads(frame)
                        if not isinstance(message, dict):
                            raise ValueError("the TUI sent something other than an RPC object")
                        forwarded = thread_request(message, jam_options, instructions)
                        if observer is not None:
                            observer(forwarded)
                        # Told to stop, no new turn is begun for the TUI. It is
                        # not noted either: a start never sent has no answer
                        # to wait for.
                        if _stopping.is_set() and message.get("method") == "turn/start":
                            continue
                        try:
                            turns.from_client(message)
                        except Exception:
                            pass
                        # Keep non-thread frames verbatim, including approvals
                        # and tool calls. No additional RPC is sent by the relay.
                        host.send(frame if forwarded is message else json.dumps(forwarded, ensure_ascii=False))
                finally:
                    # The TUI may hang up before the launcher's handler has
                    # looked: told to stop, this connection asks for its own.
                    try:
                        # A closing window hangs up the TUI and signals the
                        # launcher together, in either order: a connection
                        # that ends with a turn running waits a moment to
                        # hear whether it is a stop.
                        if not turns.idle.is_set():
                            _stopping.wait(0.5)
                        # The host stays open and read while anything is
                        # outstanding: a turn/start accepted before the TUI
                        # went is answered a moment later, named, and asked for.
                        if _stopping.is_set():
                            interrupt_turns(host, turns)
                            turns.idle.wait(1.5)
                    except Exception:
                        pass
                    with _live_lock:
                        if entry in _live:
                            _live.remove(entry)
                    host.close()
                    reader.join(timeout=3)
        except ConnectionClosed:
            pass
        except Exception as error:
            print(f"codex-jam: the session connection ended: {error}", file=sys.stderr)
        finally:
            client.close()

    return connected


def launch(executable, arguments, upstream, jam_options, instructions=None):
    """Keep a private relay alive for the foreground terminal UI's lifetime."""
    with tempfile.TemporaryDirectory(prefix="jam-codex-ui-", dir="/tmp") as directory:
        endpoint = str(Path(directory) / "ui.sock")
        lease_path = Path(directory, "lease").resolve()
        descriptor = os.open(lease_path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX)
            options = dict(jam_options)
            options["mcp_servers.jam.env.JAM_CODEX_LEASE"] = str(lease_path)
            return _launch(executable, arguments, upstream, options, instructions, endpoint, lease)


def _launch(executable, arguments, upstream, options, instructions, endpoint, lease):
    with unix_serve(handler(upstream, options, instructions), endpoint,
                    compression=None, max_size=None) as server:
        serving = threading.Thread(target=server.serve_forever, daemon=True)
        serving.start()
        process = None
        interrupt = None
        stopping = {}
        entered = [False]

        def stop(signum, frame):
            # Told to stop: the turns this launch began are interrupted first,
            # then the launcher leaves as the signal would have had it leave.
            # A second signal can arrive while the first is still being
            # handled: it does nothing but leave, so the main thread never
            # waits on a lock it already holds.
            # The guard is a plain flag set by one assignment: an Event takes
            # a lock to be set, and a signal landing inside that would wait
            # on it.
            if entered[0]:
                raise SystemExit(128 + signum)
            entered[0] = True
            _stopping.set()
            interrupt_running()
            raise SystemExit(128 + signum)

        try:
            process = subprocess.Popen([executable, "--remote", "unix://" + endpoint, *arguments])
            if threading.current_thread() is threading.main_thread():
                interrupt = signal.getsignal(signal.SIGINT)
                # The foreground TUI owns Ctrl-C. Its child process already
                # inherited the original handler before this local change.
                signal.signal(signal.SIGINT, lambda signum, frame: None)
                try:
                    for signum in STOPPING:
                        stopping[signum] = signal.signal(signum, stop)
                except Exception:
                    pass
            return process.wait()
        finally:
            for signum, previous in stopping.items():
                try:
                    signal.signal(signum, previous)
                except Exception:
                    pass
            if interrupt is not None:
                signal.signal(signal.SIGINT, interrupt)
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            fcntl.flock(lease, fcntl.LOCK_UN)
            server.shutdown()
            serving.join(timeout=3)
