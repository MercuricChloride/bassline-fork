#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# ///
"""Launch a named Codex session on the jam, preparing its local runtime."""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tomllib

PLUGIN = Path(__file__).resolve().parents[1]


class LaunchError(Exception):
    """A prerequisite for this local launch could not be prepared."""


def run(arguments, *, timeout=120, env=None):
    try:
        result = subprocess.run(arguments, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LaunchError(str(error)) from error
    if result.returncode:
        raise LaunchError(f"{Path(arguments[0]).name} exited with status {result.returncode}")


def tool(name):
    built = PLUGIN.parent / "blcli" / "bin" / name
    if built.is_file() and os.access(built, os.X_OK):
        return str(built)
    return shutil.which(name)


def codex_executable():
    specified = os.environ.get("JAM_CODEX_CODEX")
    if specified:
        found = shutil.which(specified)
        if not found:
            raise LaunchError(f"Codex executable not found: {specified}")
        return found
    found = shutil.which("codex")
    if found:
        return found
    bundled = Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    if bundled.is_file() and os.access(bundled, os.X_OK):
        return str(bundled)
    raise LaunchError("codex is not on PATH; set JAM_CODEX_CODEX to its executable")


def socket_path():
    if os.environ.get("JAM_CODEX_SOCKET"):
        return Path(os.environ["JAM_CODEX_SOCKET"]).expanduser().resolve()
    home = Path(os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")).expanduser().resolve()
    return home / "app-server-control" / "app-server-control.sock"


def has_bassline(python):
    try:
        result = subprocess.run([str(python), "-c", "import bassline"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def dependencies():
    """What the adapter needs, as this plugin's pyproject.toml names it.

    bassline is left out: it is installed from a source checkout, beside
    the plugin or wherever JAM_CODEX_BASSLINE_SOURCE says.
    """
    project = PLUGIN / "pyproject.toml"
    try:
        with open(project, "rb") as file:
            named = tomllib.load(file)["project"]["dependencies"]
    except (OSError, KeyError, tomllib.TOMLDecodeError) as error:
        raise LaunchError(f"can't read the adapter's dependencies from {project}: {error}") from error
    return [requirement for requirement in named
            if re.split(r"[\s<>=!~;\[(@]", requirement.strip(), maxsplit=1)[0].lower() != "bassline"]


def ensure_runtime(uv):
    root = Path(os.environ.get("JAM_CODEX_RUNTIME", str(Path.home() / ".bl" / "codex-runtime"))).expanduser().resolve()
    root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Separate launches can share the runtime, without two installs running
    # over one another. This lock belongs to setup only, never to the agent
    # session.
    with open(root.with_name(root.name + ".lock"), "a+b") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        python = root / "bin" / "python"
        if not python.is_file():
            print(f"-- codex-jam: preparing Python runtime in {root}", file=sys.stderr)
            # uv chooses the interpreter, one of its own, from the plugin's
            # requires-python and any .python-version above it. It may
            # have to fetch one.
            run([uv, "venv", "--quiet", "--allow-existing", "--managed-python",
                 "--project", str(PLUGIN), str(root)], timeout=600)
        # uv is the judge of whether what is installed meets the
        # requirements, and does nothing when it does.
        arguments = [uv, "pip", "install", "--quiet", "--python", str(python), *dependencies()]
        if not has_bassline(python):
            source = Path(os.environ.get("JAM_CODEX_BASSLINE_SOURCE", str(PLUGIN.parent / "blpy"))).expanduser()
            if not (source / "pyproject.toml").is_file():
                raise LaunchError("the runtime needs bassline; set JAM_CODEX_BASSLINE_SOURCE "
                                  "to packages/blpy in a bassline checkout")
            print(f"-- codex-jam: installing bassline from {source}", file=sys.stderr)
            arguments += ["--editable", str(source)]
        run(arguments)
    return python


def ensure_daemon(executable):
    socket = socket_path()
    if os.environ.get("JAM_CODEX_SOCKET"):
        if not socket.exists():
            raise LaunchError(f"the configured Codex socket does not exist: {socket}")
    else:
        # Codex probes an existing daemon or starts one. A socket pathname
        # alone could be stale and is not evidence that it is listening.
        print("-- codex-jam: starting the shared Codex daemon", file=sys.stderr)
        environment = dict(os.environ)
        if environment.get("CODEX_HOME"):
            environment["CODEX_HOME"] = str(Path(environment["CODEX_HOME"]).expanduser().resolve())
        else:
            environment.pop("CODEX_HOME", None)
        run([executable, "app-server", "daemon", "start"], timeout=30, env=environment)
        if not socket.exists():
            raise LaunchError(f"Codex started without its shared control socket: {socket}")
    return socket


def ensure_key(name):
    key = Path.home() / ".bl" / "keys" / f"{name}.blb"
    if key.exists():
        return
    clave = tool("bl-clave")
    if clave:
        try:
            run([clave, "keygen", "--out", str(key)], timeout=15)
            return
        except LaunchError as error:
            print(f"-- codex-jam: {error}; no key made for {name}, it speaks unsigned", file=sys.stderr)
    else:
        print(f"-- codex-jam: bl-clave not found; no key made for {name}, it speaks unsigned", file=sys.stderr)


def launch(name, arguments, *, named=True):
    if not name or name.startswith(".") or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in name):
        raise LaunchError("choose a jam name containing letters, digits, dots, hyphens or underscores")
    executable = codex_executable()
    if not tool("bl-jam"):
        raise LaunchError("bl-jam not found; build it with (cd packages/blcli && nim build)")
    uv = shutil.which("uv")
    if not uv:
        raise LaunchError("uv is not on PATH; the launcher builds its Python runtime with it")
    if os.environ.get("JAM_CODEX_SOCKET") and not socket_path().exists():
        raise LaunchError(f"the configured Codex socket does not exist: {socket_path()}")
    python = ensure_runtime(uv)
    socket = ensure_daemon(executable)
    if named:
        ensure_key(name)
    environment = dict(os.environ, JAM_NAME=name, JAM_CODEX_PUSH="1",
                       JAM_CODEX_SOCKET=str(socket), JAM_CODEX_CODEX=executable,
                       JAM_CODEX_PYTHON=str(python),
                       PATH=str(python.parent) + os.pathsep + os.environ.get("PATH", os.defpath))
    if environment.get("CODEX_HOME"):
        environment["CODEX_HOME"] = str(Path(environment["CODEX_HOME"]).expanduser().resolve())
    else:
        environment.pop("CODEX_HOME", None)
    os.execve(str(python), [str(python), str(PLUGIN / "scripts" / "codex_bridge.py"),
                           name, *arguments], environment)


def main(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments[:1] in (["-h"], ["--help"]):
        print("Usage: codex-jam [NAME] [CODEX-ARGS…]\n\n"
              "Prepares a private Python runtime, reuses a key for NAME, and starts\n"
              "Codex on its shared daemon with jam tools and wake delivery enabled.\n"
              "NAME defaults to JAM_NAME, otherwise a unique unsigned codex-… name.\n"
              "Further arguments go to Codex, including resume --last.")
        return 0
    if arguments and not arguments[0].startswith("-"):
        name, arguments, named = arguments[0], arguments[1:], True
    else:
        name = os.environ.get("JAM_NAME")
        named = bool(name)
        name = name or "codex-" + secrets.token_hex(8)
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    try:
        launch(name, arguments, named=named)
    except (LaunchError, OSError) as error:
        print(f"codex-jam: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
