#!/usr/bin/env python3
"""Offline behavioral checks for shared MCP routing, accounts and browser modes."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("mcp", Path(__file__).with_name("mcp.py"))
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


class SharedMcpTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, {"HOME": str(self.root), "XDG_STATE_HOME": str(self.root / "state"),
                                           "CODEX_HOME": str(self.root / "codex")})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.cfg = {"gateway": None, "remoteVersion": "0.14.3", "playwrightVersion": "0.0.82",
                    "headless": True, "bridge": False, "browsersPath": str(self.root / "browsers"),
                    "chromePath": "/windows/chrome.exe", "servers": {
                        "personal": {"url": "https://mail.example.test/mcp", "callbackPort": 18872},
                        "business": {"url": "https://mail.example.test/mcp", "callbackPort": 18873}}}

    def test_accounts_at_same_url_never_share_credentials(self):
        first, second = [mcp.cache_file(self.cfg, name, "tokens.json") for name in self.cfg["servers"]]
        self.assertNotEqual(first, second)
        self.assertEqual(first.name, second.name)
        for name in self.cfg["servers"]:
            _, env = mcp.adapter(self.cfg, name)
            self.assertEqual(env["MCP_REMOTE_CONFIG_DIR"], str(mcp.auth_dir(name)))

    def test_connect_ssh_carries_only_stdio_and_no_forwarded_agent(self):
        self.cfg["gateway"] = "operator@devbox"
        args = mcp.ssh_command(self.cfg, ["connect", "personal"])
        self.assertIn("-oForwardAgent=no", args)
        self.assertIn("-oClearAllForwardings=yes", args)
        self.assertNotIn("-L", args)
        self.assertEqual(args[-4:], ["flakelab", "mcp", "connect", "personal"])

    def test_login_forward_is_loopback_only_and_fails_if_port_taken(self):
        self.cfg["gateway"] = "operator@devbox"
        args = mcp.ssh_command(self.cfg, ["_login", "personal"], 18872)
        self.assertIn("127.0.0.1:18872:127.0.0.1:18872", args)
        self.assertIn("-oExitOnForwardFailure=yes", args)

    def test_authorization_relay_rejects_wrong_callback(self):
        url = "https://auth.example.test/authorize?state=example&redirect_uri=http%3A%2F%2F127.0.0.1%3A18872%2Foauth%2Fcallback"
        self.assertEqual(mcp.authorization_url("[1234] " + url, 18872), url)
        self.assertIsNone(mcp.authorization_url(url, 18873))
        self.assertIsNone(mcp.authorization_url(url.replace("127.0.0.1", "external.test"), 18872))
        self.assertIsNone(mcp.authorization_url(url.replace("state=example&", ""), 18872))

    def test_headless_ignores_global_extension_settings(self):
        executable = self.root / "browsers/chromium_headless_shell-1234/chrome-headless-shell-linux64/chrome-headless-shell"
        executable.parent.mkdir(parents=True)
        executable.touch(mode=0o700)
        with patch.dict(os.environ, {"PLAYWRIGHT_MCP_EXTENSION": "true", "PLAYWRIGHT_MCP_EXECUTABLE_PATH": "wrong", "PLAYWRIGHT_MCP_EXTENSION_TOKEN": "example"}), patch.object(mcp.os, "execvpe") as execute:
            mcp.browser(self.cfg, "headless")
        _, args, env = execute.call_args.args
        self.assertIn("--isolated", args)
        self.assertIn("--headless", args)
        self.assertIn(str(executable), args)
        self.assertFalse(any(k.startswith("PLAYWRIGHT_MCP_") for k in env))

    def test_bridge_only_available_when_enabled(self):
        with self.assertRaises(ValueError):
            mcp.browser(self.cfg, "bridge")
        self.cfg["bridge"] = True
        with patch.dict(os.environ, {"PLAYWRIGHT_MCP_EXTENSION_TOKEN": "example"}), patch.object(mcp.os, "execvpe") as execute:
            mcp.browser(self.cfg, "bridge")
        _, args, env = execute.call_args.args
        self.assertIn("--extension", args)
        self.assertNotIn("--isolated", args)
        self.assertEqual(env["PLAYWRIGHT_MCP_EXTENSION_TOKEN"], "example")

    def codex_credentials(self):
        source = Path(os.environ["CODEX_HOME"]) / ".credentials.json"
        data = {name: {"server_name": name, "server_url": server["url"], "client_id": "example-client",
                       "access_token": "example-access", "refresh_token": "example-refresh",
                       "expires_at": 2000000000000, "scopes": ["read"]}
                for name, server in self.cfg["servers"].items()}
        data["unrelated"] = {"example": "preserve"}
        mcp.write_private(source, data)
        return source, data

    def test_import_moves_selected_grants_and_preserves_unrelated_entries(self):
        source, data = self.codex_credentials()
        mcp.import_codex(self.cfg)
        self.assertEqual(json.loads(source.read_text()), {"unrelated": data["unrelated"]})
        self.assertEqual(json.loads(source.with_name(source.name + ".before-shared-mcp").read_text()), data)
        for name in self.cfg["servers"]:
            tokens = mcp.cache_file(self.cfg, name, "tokens.json")
            self.assertEqual(tokens.stat().st_mode & 0o777, 0o600)
            self.assertEqual(tokens.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(json.loads(tokens.read_text())["scope"], "read")
        with self.assertRaises(ValueError):
            mcp.import_codex(self.cfg)

    def test_partial_source_never_changes_native_credentials(self):
        source, data = self.codex_credentials()
        del data["business"]
        source.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            mcp.import_codex(self.cfg)
        self.assertEqual(json.loads(source.read_text()), data)
        self.assertFalse(mcp.auth_dir("personal").exists())


if __name__ == "__main__":
    unittest.main()
