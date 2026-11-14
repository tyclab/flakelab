"""Exercise the Claude launcher against fake executables and a private HOME."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
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
    if "TYCSWAP_EXIT" in os.environ:
        sys.exit(int(os.environ["TYCSWAP_EXIT"]))
    assert sys.argv[1:3] == ["start", "--"], sys.argv
    os.execv(sys.argv[3], sys.argv[3:])
sys.exit(int(os.environ.get("CHILD_EXIT", "0")))
"""


class ClaudeStartTests(unittest.TestCase):
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
        source = (SCRIPTS / "claude-start-launcher").read_text()
        source = source.replace("#!/usr/bin/env bash", f"#!{shutil.which('bash')}")
        source = source.replace("@realpath@", shutil.which("realpath"))
        self.launcher.write_text(source)
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
