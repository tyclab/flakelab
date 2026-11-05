"""Offline suite for `flakelab session-archive`: the shim and lib/session_archive/, run by test-session-archive."""

import contextlib
import io
from pathlib import Path
import subprocess
import unittest

from session_archive import cli

SHIM = Path(__file__).resolve().parent.parent / "session-archive"
UUID = "0f9b6c2e-3a41-4d7e-9c55-1b2a3c4d5e6f"


def call(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = cli.main(list(argv))
    return rc, out.getvalue(), err.getvalue()


def shim(*argv):
    return subprocess.run(["zsh", str(SHIM), *argv], capture_output=True, text=True, timeout=30, check=False)


class CliTest(unittest.TestCase):
    def test_cli_help_lists_subcommands(self):
        proc = shim("--help")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("usage: flakelab session-archive", proc.stdout)
        for name in ("run", "status", "review"):
            self.assertRegex(proc.stdout, rf"(?m)^ +{name} +\S")

    def test_cli_unknown_subcommand_exit_2(self):
        rc, out, err = call("bogus")
        self.assertEqual((rc, out), (2, ""))
        self.assertIn("invalid choice: 'bogus'", err)
        self.assertEqual(shim("bogus").returncode, 2)

    def test_cli_flags_parse_and_stubs_exit_0(self):
        for argv in (
            ["run"],
            ["run", "--session", UUID, "--dry-run", "--limit", "3", "--keep"],
            ["status"],
            ["status", "--json"],
            ["review"],
        ):
            with self.subTest(argv=argv):
                self.assertEqual(call(*argv)[0], 0)

    def test_cli_usage_errors_exit_2(self):
        for argv in (
            [],
            ["run", "--session"],
            ["run", "--session", "not-a-uuid"],
            ["run", "--limit", "x"],
            ["run", "--limit", "0"],
            ["review", "--json"],
            ["status", "--dry-run"],
        ):
            with self.subTest(argv=argv):
                rc, out, err = call(*argv)
                self.assertEqual((rc, out), (2, ""))
                self.assertIn("usage: flakelab session-archive", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
