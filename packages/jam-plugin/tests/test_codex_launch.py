"""Launcher setup in isolated homes, without a jam, Codex daemon or network."""

import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import chdir, redirect_stderr, redirect_stdout
from unittest.mock import patch


PLUGIN = Path(__file__).resolve().parents[1]
SOURCE = PLUGIN / "scripts" / "codex_launch.py"


def load_launcher():
    spec = importlib.util.spec_from_file_location("jam_codex_launch_tests", SOURCE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Commands:
    """Stand-ins for imports, uv, keygen and daemon startup, recorded in order."""

    def __init__(self, fixture):
        self.fixture = fixture
        self.calls = []
        self.ready = False
        self.pip_fails = False
        self.key_fails = False
        self.daemon_fails = False
        self.daemon_environments = []

    def run(self, arguments, **kwargs):
        arguments = [str(argument) for argument in arguments]
        self.calls.append(arguments)
        code = 0
        if "-c" in arguments:
            code = 0 if self.ready else 1
        elif "venv" in arguments:
            python = Path(arguments[-1]) / "bin" / "python"
            python.parent.mkdir(parents=True, exist_ok=True)
            python.write_text("#!/bin/sh\nexit 0\n")
            python.chmod(0o755)
        elif "pip" in arguments:
            if self.pip_fails:
                code = 1
            elif "--editable" in arguments:
                self.ready = True
        elif arguments[1:4] == ["app-server", "daemon", "start"]:
            self.daemon_environments.append(dict(kwargs.get("env") or {}))
            if self.daemon_fails:
                code = 1
            else:
                self.fixture.socket.parent.mkdir(parents=True, exist_ok=True)
                self.fixture.socket.write_text("fixture listening socket")
        elif "keygen" in arguments:
            if self.key_fails:
                code = 1
            else:
                key = Path(arguments[arguments.index("--out") + 1])
                key.parent.mkdir(parents=True, exist_ok=True)
                key.write_bytes(b"fake-key")
        else:
            raise AssertionError(f"unexpected child invocation: {arguments!r}")
        completed = subprocess.CompletedProcess(arguments, code, stdout="", stderr="fixture failure" if code else "")
        if code and kwargs.get("check"):
            raise subprocess.CalledProcessError(code, arguments, output=completed.stdout,
                                              stderr=completed.stderr)
        return completed

    def matching(self, word):
        return [arguments for arguments in self.calls if word in arguments]


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="codex jam setup ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.plugin = self.root / "checkout" / "packages" / "jam-plugin"
        (self.plugin / "scripts").mkdir(parents=True)
        (self.plugin / "bin").mkdir()
        (self.plugin / "pyproject.toml").write_text(
            '[project]\nname = "jam-plugin"\ndependencies = ["websockets>=17,<18", "bassline"]\n')
        (self.plugin.parent / "blpy" / "src").mkdir(parents=True)
        (self.plugin.parent / "blpy" / "pyproject.toml").write_text("[project]\nname='bassline'\n")
        self.home = self.root / "home"
        self.home.mkdir()
        self.runtime = self.home / ".bl" / "codex-runtime"
        self.socket = self.home / ".codex" / "app-server-control" / "app-server-control.sock"
        self.command_bin = self.root / "commands"
        self.command_bin.mkdir()
        for name in ("codex", "bl-jam", "bl-clave", "uv"):
            command = self.command_bin / name
            command.write_text("#!/bin/sh\nexit 0\n")
            command.chmod(0o755)
        self.env = {"HOME": str(self.home), "PATH": str(self.command_bin),
                    "JAM_CODEX_RUNTIME": str(self.runtime)}
        self.commands = Commands(self)
        with patch.dict(os.environ, self.env, clear=True):
            self.launcher = load_launcher()

    def invoke(self, arguments, expected_code=0):
        self.stderr = io.StringIO()
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(self.launcher, "PLUGIN", self.plugin), \
                patch.object(self.launcher.subprocess, "run", side_effect=self.commands.run), \
                patch.object(sys, "argv", [str(SOURCE), *arguments]), \
                patch.object(self.launcher.os, "execv") as execv, \
                patch.object(self.launcher.os, "execvp") as execvp, \
                patch.object(self.launcher.os, "execve") as execve, \
                redirect_stderr(self.stderr):
            result = self.launcher.main()
        executed = [call for execute in (execv, execvp, execve) for call in execute.call_args_list]
        self.assertEqual(result, expected_code)
        if expected_code:
            self.assertEqual(executed, [], "a failed setup never starts the session")
            return
        self.assertEqual(len(executed), 1, "the successful setup hands off exactly once")
        return executed[0].args

    def test_first_launch_sets_up_runtime_key_and_shared_daemon(self):
        executable, arguments, *environment = self.invoke(["test-reader"])
        self.assertEqual(Path(executable), self.runtime / "bin" / "python")
        self.assertEqual(Path(arguments[1]), self.plugin / "scripts" / "codex_bridge.py")
        self.assertEqual(arguments[2:], ["test-reader"])
        self.assertTrue(self.commands.matching("venv"))
        self.assertTrue(self.commands.matching("pip"))
        self.assertTrue(self.commands.matching("keygen"))
        self.assertTrue(self.commands.matching("daemon"))
        self.assertTrue(self.socket.exists())
        self.assertTrue((self.home / ".bl" / "keys" / "test-reader.blb").exists())
        self.assertFalse((self.home / ".codex" / "config.toml").exists())
        venv = self.commands.matching("venv")[0]
        self.assertEqual(venv[0], str(self.command_bin / "uv"))
        self.assertEqual(venv[-1], str(self.runtime))
        self.assertIn("--managed-python", venv, "the runtime's Python is one of uv's")
        self.assertEqual(venv[venv.index("--project") + 1], str(self.plugin))
        self.assertNotIn("--python", venv, "uv chooses the interpreter from the plugin's project")
        self.assertNotIn(sys.executable, venv)
        pip = self.commands.matching("pip")[0]
        self.assertEqual(pip[:3], [str(self.command_bin / "uv"), "pip", "install"])
        self.assertEqual(pip[pip.index("--python") + 1], str(self.runtime / "bin" / "python"))
        self.assertEqual(pip[pip.index("--editable") + 1], str(self.plugin.parent / "blpy"))
        self.assertIn("websockets>=17,<18", pip, "requirements come from the plugin's pyproject.toml")
        self.assertNotIn("bassline", pip, "bassline comes from its source, never from an index")

    def test_second_launch_reuses_runtime_key_and_probes_daemon(self):
        self.invoke(["test-reader"])
        self.commands.calls.clear()
        self.invoke(["test-reader"])
        self.assertEqual(self.commands.matching("venv"), [])
        self.assertEqual(self.commands.matching("keygen"), [])
        self.assertEqual(len(self.commands.matching("daemon")), 1)
        pip, = self.commands.matching("pip")
        self.assertIn("websockets>=17,<18", pip, "uv checks the runtime against pyproject.toml every launch")
        self.assertNotIn("--editable", pip, "bassline is left as it is once it imports")

    def test_missing_bassline_source_stops_before_key_or_daemon(self):
        (self.plugin.parent / "blpy" / "pyproject.toml").unlink()
        self.invoke(["test-reader"], expected_code=1)
        self.assertEqual(self.commands.matching("pip"), [])
        self.assertEqual(self.commands.matching("keygen"), [])
        self.assertEqual(self.commands.matching("daemon"), [])
        self.assertIn("JAM_CODEX_BASSLINE_SOURCE", self.stderr.getvalue())

    def test_existing_default_socket_is_checked_and_repaired_by_codex(self):
        self.socket.parent.mkdir(parents=True)
        self.socket.write_text("stale pathname")
        self.invoke(["test-reader"])
        self.assertEqual(len(self.commands.matching("daemon")), 1)
        self.assertEqual(self.socket.read_text(), "fixture listening socket")

    def test_existing_custom_socket_does_not_start_default_daemon(self):
        socket = self.root / "other daemon.sock"
        socket.write_text("selected custom socket")
        self.env["JAM_CODEX_SOCKET"] = str(socket)
        _, _, environment = self.invoke(["test-reader"])
        self.assertEqual(environment["JAM_CODEX_SOCKET"], str(socket))
        self.assertEqual(self.commands.matching("daemon"), [])
        self.assertEqual(socket.read_text(), "selected custom socket")
        self.assertFalse(self.socket.exists())

    def test_codex_arguments_and_paths_with_spaces_survive_handoff(self):
        _, arguments, *_ = self.invoke([
            "reader.one", "--", "--no-alt-screen", "a prompt with spaces", "-c", "model='example'",
        ])
        self.assertEqual(arguments[2:], [
            "reader.one", "--no-alt-screen", "a prompt with spaces", "-c", "model='example'",
        ])

    def test_dependency_failure_stops_before_key_or_daemon(self):
        self.commands.pip_fails = True
        self.invoke(["test-reader"], expected_code=1)
        self.assertEqual(self.commands.matching("keygen"), [])
        self.assertEqual(self.commands.matching("daemon"), [])

    def test_missing_custom_socket_does_not_start_default_daemon(self):
        self.env["JAM_CODEX_SOCKET"] = str(self.root / "other daemon.sock")
        self.invoke(["test-reader"], expected_code=1)
        self.assertEqual(self.commands.matching("daemon"), [])

    def test_daemon_failure_stops_before_handoff(self):
        self.commands.daemon_fails = True
        self.invoke(["test-reader"], expected_code=1)
        self.assertTrue(self.commands.matching("daemon"))

    def test_explicit_jam_name_wins_over_environment(self):
        self.env["JAM_NAME"] = "from-env"
        _, arguments, *_ = self.invoke(["from-command", "--no-alt-screen"])
        self.assertEqual(arguments[2:], ["from-command", "--no-alt-screen"])
        self.assertTrue((self.home / ".bl" / "keys" / "from-command.blb").exists())
        self.assertFalse((self.home / ".bl" / "keys" / "from-env.blb").exists())

    def test_jam_name_from_environment_keeps_leading_codex_options(self):
        self.env["JAM_NAME"] = "from-env"
        _, arguments, *_ = self.invoke(["--no-alt-screen", "prompt"])
        self.assertEqual(arguments[2:], ["from-env", "--no-alt-screen", "prompt"])

    def test_unnamed_launches_choose_distinct_speakers(self):
        _, first, *_ = self.invoke(["--no-alt-screen"])
        _, second, *_ = self.invoke(["--no-alt-screen"])
        self.assertRegex(first[2], r"^codex-[0-9a-f]+$")
        self.assertRegex(second[2], r"^codex-[0-9a-f]+$")
        self.assertNotEqual(first[2], second[2])
        self.assertEqual(self.commands.matching("keygen"), [])

    def test_invalid_name_fails_before_setup(self):
        self.invoke(["../unsafe"], expected_code=1)
        self.assertEqual(self.commands.calls, [])

    def test_runtime_python_and_original_environment_reach_adapter(self):
        self.env.update({"JAM_AT": "127.0.0.1:4000", "JAM_CODEX_STATE": str(self.root / "state"),
                         "JAM_CODEX_REPLAY": "1"})
        executable, arguments, environment = self.invoke(["test-reader"])
        self.assertEqual(environment["JAM_CODEX_PYTHON"], executable)
        self.assertEqual(environment["JAM_CODEX_PUSH"], "1")
        self.assertEqual(environment["JAM_NAME"], "test-reader")
        self.assertEqual(environment["PATH"], str(self.runtime / "bin") + os.pathsep + self.env["PATH"])
        for variable in ("HOME", "JAM_AT", "JAM_CODEX_STATE", "JAM_CODEX_REPLAY"):
            self.assertEqual(environment[variable], self.env[variable])
        self.assertEqual(Path(environment["JAM_CODEX_SOCKET"]), self.socket)
        self.assertEqual(environment["JAM_CODEX_CODEX"], str(self.command_bin / "codex"))

    def test_relative_runtime_has_absolute_interpreter_and_path_for_mcp_cwd(self):
        self.env["JAM_CODEX_RUNTIME"] = "relative runtime"
        with chdir(self.root):
            executable, arguments, environment = self.invoke(["test-reader"])
        expected = self.root / "relative runtime" / "bin" / "python"
        self.assertEqual(Path(executable), expected)
        self.assertEqual(arguments[0], str(expected))
        self.assertEqual(environment["JAM_CODEX_PYTHON"], str(expected))
        self.assertEqual(environment["PATH"].split(os.pathsep)[0], str(expected.parent))

    def test_relative_codex_home_stays_absolute_after_handoff(self):
        self.env["CODEX_HOME"] = "relative codex home"
        self.socket = self.root / "relative codex home" / "app-server-control" / "app-server-control.sock"
        with chdir(self.root):
            _, _, environment = self.invoke(["test-reader"])
        self.assertEqual(environment["CODEX_HOME"], str(self.root / "relative codex home"))
        self.assertEqual(environment["JAM_CODEX_SOCKET"], str(self.socket))

    def test_tilde_codex_home_is_expanded_before_daemon_start(self):
        self.env["CODEX_HOME"] = "~/custom"
        custom_home = self.home / "custom"
        self.socket = custom_home / "app-server-control" / "app-server-control.sock"
        _, _, environment = self.invoke(["test-reader"])
        self.assertEqual(len(self.commands.daemon_environments), 1)
        self.assertEqual(self.commands.daemon_environments[0]["CODEX_HOME"], str(custom_home))
        self.assertEqual(environment["CODEX_HOME"], str(custom_home))
        self.assertEqual(environment["JAM_CODEX_SOCKET"], str(self.socket))

    def test_empty_codex_home_uses_default_and_is_removed_before_daemon_start(self):
        self.env["CODEX_HOME"] = ""
        _, _, environment = self.invoke(["test-reader"])
        self.assertEqual(len(self.commands.daemon_environments), 1)
        self.assertNotIn("CODEX_HOME", self.commands.daemon_environments[0])
        self.assertNotIn("CODEX_HOME", environment)
        self.assertEqual(environment["JAM_CODEX_SOCKET"], str(self.socket))

    def test_keygen_failure_continues_unsigned(self):
        self.commands.key_fails = True
        self.invoke(["test-reader"])
        self.assertTrue(self.commands.matching("keygen"))
        self.assertFalse((self.home / ".bl" / "keys" / "test-reader.blb").exists())
        self.assertIn("it speaks unsigned", self.stderr.getvalue())

    def test_missing_bl_jam_fails_before_setup(self):
        (self.command_bin / "bl-jam").unlink()
        self.invoke(["test-reader"], expected_code=1)
        self.assertEqual(self.commands.calls, [])

    def test_missing_uv_fails_before_setup(self):
        (self.command_bin / "uv").unlink()
        self.invoke(["test-reader"], expected_code=1)
        self.assertEqual(self.commands.calls, [])
        self.assertIn("uv is not on PATH", self.stderr.getvalue())

    def test_unreadable_dependencies_stop_before_key_or_daemon(self):
        (self.plugin / "pyproject.toml").write_text("[project]\nname = 'jam-plugin'\n")
        self.invoke(["test-reader"], expected_code=1)
        self.assertEqual(self.commands.matching("pip"), [])
        self.assertEqual(self.commands.matching("keygen"), [])
        self.assertEqual(self.commands.matching("daemon"), [])

    def test_existing_global_config_is_preserved(self):
        config = self.home / ".codex" / "config.toml"
        config.parent.mkdir(parents=True)
        before = b'model = "fixture"\n[mcp_servers.jam]\ncommand = "older-wrapper"\n'
        config.write_bytes(before)
        self.invoke(["test-reader"])
        self.assertEqual(config.read_bytes(), before)

    def test_help_has_no_setup_side_effects(self):
        stdout = io.StringIO()
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(self.launcher, "PLUGIN", self.plugin), \
                patch.object(self.launcher.subprocess, "run", side_effect=self.commands.run), \
                patch.object(self.launcher.os, "execve") as execute, \
                redirect_stdout(stdout):
            self.assertEqual(self.launcher.main(["--help"]), 0)
        self.assertEqual(self.commands.calls, [])
        execute.assert_not_called()
        self.assertFalse((self.home / ".bl").exists())
        self.assertIn("Usage: codex-jam", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
