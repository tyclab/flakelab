"""Exercise the Claude launcher against fake executables and a private HOME."""

import json
import os
import pty
import select
import shlex
import signal
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import termios
import time
import unittest


SCRIPTS = Path(__file__).resolve().parent.parent
RECORDER = """
import json
import os
import sys
with open(os.environ["CALLS"], "a") as calls:
    calls.write(json.dumps({"tool": TOOL, "argv": sys.argv[1:],
                           "env": dict(os.environ)}) + "\\n")
if TOOL == "tycswap":
    if sys.argv[1:] == ["start", "--next", "show"]:
        print(os.environ.get("NEXT_REPLY", "none"))
        if "NEXT_ERROR" in os.environ:
            print("fixture query diagnostic", file=sys.stderr)
            sys.exit(int(os.environ["NEXT_ERROR"]))
        sys.exit(0)
    if sys.argv[1:] == ["start", "--mythos"]:
        if "MYTHOS_REFUSED" in os.environ:
            print("fixture: no Mythos login", file=sys.stderr)
            sys.exit(73)
        native = os.path.join(os.environ["HOME"], ".local/bin/claude")
        os.execv(native, [native])
    if "TYCSWAP_EXIT" in os.environ:
        sys.exit(int(os.environ["TYCSWAP_EXIT"]))
    assert sys.argv[1:3] == ["start", "--"], sys.argv
    os.execv(sys.argv[3], sys.argv[3:])
if "RECEIVE_LINE" in os.environ:
    print("fixture client ready", flush=True)
    with open(os.environ["RECEIVE_LINE"], "w") as receiver:
        receiver.write(sys.stdin.readline())
sys.exit(int(os.environ.get("CHILD_EXIT", "0")))
"""


class LauncherFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="claude-start-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home with spaces"
        self.native = self.home / ".local/bin/claude"
        self.launcher = self.home / ".local/share/flakelab/claude/bin/claude"
        self.bin = self.root / "bin"
        for folder in (self.native.parent, self.launcher.parent, self.bin):
            folder.mkdir(parents=True)
        # Like claude.nix, pin tools without changing the child's PATH.
        packaged = os.environ.get("FLAKELAB_TEST_CLAUDE_LAUNCHER")
        if packaged:
            shutil.copyfile(packaged, self.launcher)
        else:
            self.render_launcher(SCRIPTS / "lib/claude-model-picker.py")
        self.launcher.chmod(0o755)
        self.write_recorder(self.native, "claude")
        self.write_recorder(self.bin / "tycswap", "tycswap")
        self.calls_file = self.root / "calls.jsonl"
        self.env = {
            "HOME": str(self.home),
            "PATH": os.pathsep.join(map(str, (self.launcher.parent, self.bin, self.native.parent))),
            "CALLS": str(self.calls_file),
            "LC_ALL": "C.UTF-8",
            "SHLVL": "3",
            "PWD": str(Path.cwd()),
        }

    def render_launcher(self, picker):
        source = (SCRIPTS / "claude-start-launcher").read_text()
        source = source.replace("#!/usr/bin/env bash", f"#!{shutil.which('bash')}")
        source = source.replace("@realpath@", shutil.which("realpath"))
        source = source.replace("@python@", sys.executable)
        self.launcher.write_text(source.replace("@picker@", str(picker)))

    def write_recorder(self, target, tool):
        target.write_text(f"#!{sys.executable}\nTOOL = {tool!r}\n" + RECORDER)
        target.chmod(0o755)

    def run_launcher(self, *args):
        return subprocess.run(["claude", *args], env=self.env, capture_output=True, text=True)

    def calls(self):
        if not self.calls_file.exists():
            return []
        return [json.loads(line) for line in self.calls_file.read_text().splitlines()]

    def assert_tools(self, expected):
        calls = self.calls()
        self.assertEqual([call["tool"] for call in calls], expected)
        return calls

    def direct_environment(self):
        # The Nix Python interpreter can itself add runtime variables; compare
        # the same native executable launched directly with the shell launcher.
        subprocess.run([str(self.native)], env=self.env, capture_output=True, check=False)
        environment = self.calls()[0]["env"]
        self.calls_file.unlink()
        return environment


class ClaudeStartTests(LauncherFixture):
    def test_routes_once_and_preserves_arguments_and_environment(self):
        args = ["--resume", "a b", "", "--bare", "quote'\"$;*", "line\nbreak"]
        self.env.update({
            "CLAUDE_CONFIG_DIR": "",
            "ANTHROPIC_API_KEY": "fixture-key",
            "CLAUDECODE": "1",
            "CUSTOM_VALUE": "space = value\nsecond line",
            # Even inherited exported variables matching ordinary shell names survive.
            "real": "inherited-real",
            "tycswap": "inherited-tycswap",
        })
        expected_environment = self.direct_environment()
        result = self.run_launcher(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        tycswap, native = self.assert_tools(["tycswap", "claude"])
        self.assertEqual(tycswap["argv"], ["start", "--", str(self.native), *args])
        self.assertEqual(native["argv"], args)
        self.assertEqual(tycswap["env"], expected_environment)
        self.assertEqual(native["env"], expected_environment)
        self.assertEqual((result.stdout, result.stderr), ("", ""))

    def test_child_nonzero_is_returned_without_retry(self):
        self.env["CHILD_EXIT"] = "37"
        result = self.run_launcher("--print", "hello")
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assert_tools(["tycswap", "claude"])

    def test_tycswap_nonzero_is_returned_without_native_fallback(self):
        self.env["TYCSWAP_EXIT"] = "73"
        result = self.run_launcher("--version")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assert_tools(["tycswap"])

    def test_missing_tycswap_executes_native_once(self):
        (self.bin / "tycswap").unlink()
        self.env["CHILD_EXIT"] = "42"
        expected_environment = self.direct_environment()
        result = self.run_launcher("", "a b")
        self.assertEqual(result.returncode, 42, result.stderr)
        native, = self.assert_tools(["claude"])
        self.assertEqual(native["argv"], ["", "a b"])
        self.assertEqual(native["env"], expected_environment)

    def test_symlinked_native_is_resolved_without_changing_installer_link(self):
        versioned = self.root / "native version"
        self.native.rename(versioned)
        intermediate = self.root / "native link"
        intermediate.symlink_to(versioned)
        self.native.symlink_to(intermediate)
        result = self.run_launcher("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        tycswap, _ = self.assert_tools(["tycswap", "claude"])
        self.assertEqual(tycswap["argv"], ["start", "--", str(versioned), "--help"])
        self.assertEqual(self.native.readlink(), intermediate)

    def test_launcher_wins_over_native_on_path(self):
        self.assertEqual(shutil.which("claude", path=self.env["PATH"]), str(self.launcher))
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_tools(["tycswap", "claude"])

    def test_native_symlink_to_launcher_fails_before_tycswap(self):
        self.native.unlink()
        self.native.symlink_to(self.launcher)
        result = self.run_launcher()
        self.assertEqual(result.returncode, 126, result.stderr)
        self.assertIn("points to this launcher", result.stderr)
        self.assert_tools([])

    def test_native_hardlink_to_launcher_fails_before_tycswap(self):
        self.native.unlink()
        os.link(self.launcher, self.native)
        result = self.run_launcher()
        self.assertEqual(result.returncode, 126, result.stderr)
        self.assertIn("points to this launcher", result.stderr)
        self.assert_tools([])

    def test_missing_native_fails_without_searching_path_for_another_claude(self):
        self.native.unlink()
        self.write_recorder(self.bin / "claude", "unexpected")
        result = self.run_launcher()
        self.assertEqual(result.returncode, 127, result.stderr)
        self.assertIn("flakelab update", result.stderr)
        self.assert_tools([])

    def test_nonexecutable_native_fails(self):
        self.native.chmod(0o644)
        result = self.run_launcher()
        self.assertEqual(result.returncode, 127, result.stderr)
        self.assert_tools([])

    def test_directory_at_native_path_fails(self):
        self.native.unlink()
        self.native.mkdir()
        result = self.run_launcher()
        self.assertEqual(result.returncode, 127, result.stderr)
        self.assert_tools([])


SHELL_PROMPT = b"fixture-shell> "
QUERY = ["start", "--next", "show"]


class PickerTests(LauncherFixture):
    def setUp(self):
        super().setUp()
        self.settings = self.home / ".claude/settings.json"
        self.settings.parent.mkdir()
        self.settings.write_text('{"model":"opus"}')
        self.env.update({
            "ZDOTDIR": str(self.home), "TERM": "dumb",
            "__ETC_ZSHENV_SOURCED": "1", "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
        })
        for tool in ("zsh", "bash", "cat"):
            (self.bin / tool).symlink_to(shutil.which(tool))
        hook = shlex.quote(str(SCRIPTS / "lib/claude-model-prompt.zsh"))
        (self.home / ".zshrc").write_text(
            f"unsetopt zle promptcr promptsp\nPS1='fixture-shell> '\n"
            f"if [[ -f {hook} ]]; then source {hook}; fi\n"
        )
        pid, self.fd = pty.fork()
        if pid == 0:
            os.chdir(self.home)
            os.execve(self.bin / "zsh", ["zsh", "-di"], self.env)
        self.addCleanup(self.close_shell, pid)
        self.wait_for(SHELL_PROMPT)

    def close_shell(self, pid):
        os.close(self.fd)
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)

    def wait_for(self, marker):
        output = b""
        end = time.monotonic() + 5
        while marker not in output:
            if SHELL_PROMPT in output or not select.select([self.fd], [], [], max(0, end - time.monotonic()))[0]:
                self.fail(f"expected {marker!r}, terminal showed {output!r}")
            output += os.read(self.fd, 4096)
        return output

    def command(self, line):
        os.write(self.fd, line.encode() + b"\n")
        return self.wait_for(SHELL_PROMPT)

    def wait_for_picker(self, model):
        os.write(self.fd, b"claude\n")
        # The last option completes the line. Send only the key, without Enter.
        last_option = "Fable" if "opus" in model.lower() else "Opus"
        output = self.wait_for((last_option + ": ").encode()).decode()
        echo, line = output.splitlines()
        self.assertEqual(echo, "claude")
        self.assertIn("Enter", line)
        self.assertIn(model.lower(), line.lower())
        return line.lower()

    def choose(self, model, key):
        line = self.wait_for_picker(model)
        os.write(self.fd, key)
        return line, self.wait_for(SHELL_PROMPT)

    def assert_calls(self, swap_args, native_args):
        calls = self.calls()
        expected = [("tycswap", args) for args in swap_args]
        if native_args is not None:
            expected.append(("claude", native_args))
        self.assertEqual([(call["tool"], call["argv"]) for call in calls], expected)
        for call in calls:
            self.assertNotIn("FLAKELAB_CLAUDE_PROMPT_PID", call["env"])
        self.calls_file.unlink(missing_ok=True)

    def normal_start(self, *args):
        return ["start", "--", str(self.native), *args]

    def test_one_key_or_enter_selects_once_and_rereads_the_configured_model(self):
        cases = [
            ("opus", b"\r", self.normal_start(), []),
            ("opus", b"o", self.normal_start(), []),
            ("opus", b"m", ["start", "--mythos"], []),
            ("opus", b"f", self.normal_start("--model", "fable"), ["--model", "fable"]),
            ("claude-mythos-5-2", b"o", self.normal_start("--model", "opus"), ["--model", "opus"]),
            ("fable", b"x", self.normal_start(), []),
        ]
        for model, key, invocation, native_args in cases:
            with self.subTest(model=model, key=key):
                self.settings.write_text(json.dumps({"model": model}))
                line, rest = self.choose(model, key)
                for family in ("mythos", "fable", "opus"):
                    if family not in model:
                        self.assertIn(family, line)
                    else:
                        self.assertEqual(line.count(family), 1)
                self.assertNotIn(b"Enter", rest)
                self.assert_calls([QUERY, invocation], native_args)

    def test_unconfigured_default_keeps_all_three_options(self):
        self.settings.unlink()
        line, _ = self.choose("Claude default", b"\r")
        for family in ("mythos", "fable", "opus"):
            self.assertIn(family, line)
        self.assert_calls([QUERY, self.normal_start()], [])

    def test_current_model_follows_the_launch_environment_and_project_settings(self):
        local = self.home / "project" / ".claude"
        local.mkdir(parents=True)
        self.command("cd project")
        (local / "settings.json").write_text('{"model":"fable"}')
        self.choose("fable", b"\r")
        self.assert_calls([QUERY, self.normal_start()], [])
        (local / "settings.local.json").write_text('{"env":{"ANTHROPIC_MODEL":"opus[1m]"}}')
        self.choose("opus[1m]", b"\r")
        self.assert_calls([QUERY, self.normal_start()], [])
        self.command("export ANTHROPIC_MODEL=claude-mythos-5-2")
        self.choose("claude-mythos-5-2", b"\r")
        self.assert_calls([QUERY, self.normal_start()], [])

    def test_ctrl_c_starts_nothing_and_restores_the_terminal(self):
        before = termios.tcgetattr(self.fd)
        self.choose("opus", b"\x03")
        self.assertEqual(self.command("print $?"), b"print $?\r\n130\r\n" + SHELL_PROMPT)
        self.assert_calls([QUERY], None)
        self.assertEqual(termios.tcgetattr(self.fd), before)
        self.assertIn(b"\r\nalive\r\n", self.command("print -r -- alive"))

    def test_selected_client_receives_the_rest_of_a_single_write(self):
        received = self.home / "received"
        self.command('export RECEIVE_LINE="$HOME/received"')
        self.choose("opus", b"fthe first turn\r")
        self.assertEqual(received.read_text(), "the first turn\n")
        self.assert_calls([QUERY, self.normal_start("--model", "fable")], ["--model", "fable"])

    def test_escape_key_discards_its_pending_bytes_before_start(self):
        received = self.home / "received"
        self.command('export RECEIVE_LINE="$HOME/received"')
        for sequence in (b"\x1b[A", b"\x1b[<0;12;8M", b"\x1b[M !!", b"\x1b"):
            with self.subTest(sequence=sequence):
                self.calls_file.unlink(missing_ok=True)
                self.wait_for_picker("opus")
                typed_ahead = b"typed " if sequence != b"\x1b" else b""
                os.write(self.fd, sequence + typed_ahead)
                self.wait_for(b"fixture client ready")
                os.write(self.fd, b"first turn\r")
                self.wait_for(SHELL_PROMPT)
                self.assertEqual(received.read_bytes(), typed_ahead + b"first turn\n")
                self.assert_calls([QUERY, self.normal_start()], [])

    def test_invalid_picker_answer_or_failed_picker_uses_ordinary_start(self):
        picker = self.root / "fixture-picker.py"
        self.render_launcher(picker)
        self.command("export CHILD_EXIT=37")
        for label, script, failure in (
            ("raises", "raise RuntimeError('fixture picker error')", True),
            ("empty", "", False),
            ("unknown", "print('other')", False),
            ("failed selection", "print('mythos'); raise SystemExit(2)", True),
            ("failed cancellation", "print('cancel'); raise SystemExit(2)", True),
        ):
            with self.subTest(picker=label):
                self.calls_file.unlink(missing_ok=True)
                picker.write_text(script)
                terminal = self.command("claude")
                messages = terminal.removeprefix(b"claude\r\n").removesuffix(SHELL_PROMPT).splitlines()
                if failure:
                    self.assertEqual(len(messages), 1, terminal)
                    self.assertTrue(messages[0].strip())
                self.assertNotIn(b"Traceback", terminal)
                self.assertEqual(self.command("print $?"), b"print $?\r\n37\r\n" + SHELL_PROMPT)
                self.assert_calls([self.normal_start()], [])

    def test_refused_mythos_shows_the_reason_and_starts_nothing(self):
        self.command("export MYTHOS_REFUSED=1")
        _, rest = self.choose("opus", b"m")
        self.assertIn(b"fixture: no Mythos login", rest)
        self.assert_calls([QUERY, ["start", "--mythos"]], None)

    def test_queued_unknown_unreadable_or_unsupported_query(self):
        for answer, status in (("mythos", 0), ("future", 0), ("", 0), ("none", 1), ("", 2)):
            with self.subTest(answer=answer, status=status):
                self.calls_file.unlink(missing_ok=True)
                self.command(f"export NEXT_REPLY={shlex.quote(answer)} NEXT_ERROR={status}")
                self.assertEqual(self.command("claude"), b"claude\r\n" + SHELL_PROMPT)
                self.assert_calls([QUERY, self.normal_start()], [])

    def test_arguments_pipes_redirections_and_other_shells(self):
        for command, args in [
            ("claude ''", [""]), ("claude --model fable", ["--model", "fable"]),
            ("claude --resume 'a b'", ["--resume", "a b"]),
            ("print -r -- fixture | claude", []), ("claude | cat", []),
            ("claude </dev/null", []), ("claude >out", []), ("claude 2>err", []),
            ("zsh -fc claude", []), ("zsh -dic claude", []), ("bash -c claude", []),
            ("bash --noprofile --norc -ic claude", []),
        ]:
            with self.subTest(command=command):
                self.assertNotIn(b"Enter", self.command(command))
                self.assert_calls([self.normal_start(*args)], args)
        for path in ("out", "err"):
            self.assertEqual((self.home / path).read_bytes(), b"")

    def test_each_redirected_descriptor_suppresses_even_a_marked_launch(self):
        for redirect in ("</dev/null", ">out", "2>err"):
            with self.subTest(redirect=redirect):
                self.command(f"FLAKELAB_CLAUDE_PROMPT_PID=$$ claude {redirect}")
                self.assert_calls([self.normal_start()], [])
        for path in ("out", "err"):
            self.assertEqual((self.home / path).read_bytes(), b"")

    def test_agent_ci_and_opt_out_flags_and_identity_variables(self):
        for key in (
            "CI", "CLAUDECODE", "CODEX_THREAD_ID", "TYCSWAP_NO_PROMPT", "FLAKELAB_NO_PROMPT",
            "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS",
            "ANTHROPIC_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        ):
            with self.subTest(key=key):
                self.command(f"export {key}=fixture")
                self.assertEqual(self.command("claude"), b"claude\r\n" + SHELL_PROMPT)
                self.assert_calls([self.normal_start()], [])
                self.command(f"unset {key}")
        self.command("CLAUDE_CONFIG_DIR=''")  # Even an empty, shell-local identity.
        self.command("claude")
        self.assert_calls([self.normal_start()], [])

    def test_alias_and_function_do_not_enter_the_picker(self):
        for define, remove in (("alias claude='command claude'", "unalias claude"),
                               ("alias -g claude='command claude'", "unalias claude"),
                               ("claude() { command claude; }", "unfunction claude")):
            self.command(define)
            self.assertEqual(self.command("claude"), b"claude\r\n" + SHELL_PROMPT)
            self.assert_calls([self.normal_start()], [])
            self.command(remove)

    def test_bare_without_tycswap_starts_native_once(self):
        (self.bin / "tycswap").unlink()
        self.assertEqual(self.command("claude"), b"claude\r\n" + SHELL_PROMPT)
        self.assert_calls([], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
