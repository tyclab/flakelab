#!/usr/bin/env python3
"""Offline behavioral checks for shared MCP routing and accounts, and for the
headless browser server when FLAKELAB_MCP_HEADLESS names its launcher
(FLAKELAB_MCP_HEADLESS_ARGS adds arguments to it)."""
import http.server
import importlib.util
import io
import multiprocessing
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("mcp", Path(__file__).with_name("mcp.py"))
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


class NativeMcpTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.secret = Path(self.temp.name) / 'secrets.env'
        self.secret.write_text('FIXTURE_KEY=fixture\n')
        self.servers = {'hub': {'url': 'https://mcp.example.test/mcp', 'tokenEnv': 'FIXTURE_KEY', 'clientsAgree': True}}

    def check(self, **kwargs):
        return mcp.mcp_native.check(self.servers, secret_file=self.secret, **kwargs)

    def test_missing_credential_and_stale_shell_fail_without_leaking_values(self):
        self.assertEqual(self.check(env={})[0]['status'], 'credential-missing-from-environment')
        self.secret.write_text('FIXTURE_KEY=new-fixture-value\nUNRELATED=unrelated-fixture-value\n')
        result = self.check(env={'FIXTURE_KEY': 'old-fixture-value'})
        self.assertEqual(result[0]['status'], 'fresh-environment-source-mismatch')
        self.assertNotIn('fixture-value', json.dumps(result))

    def test_client_mismatch_and_unsafe_endpoints_never_send_credentials(self):
        with patch.object(mcp.mcp_native, 'probe') as probe:
            for url in ('http://example.test/mcp', 'https://user:pass@example.test/mcp', 'https://example.test/mcp?token=fixture', 'https://[invalid', 'https://example.test:bad/mcp'):
                self.servers['hub']['url'] = url
                self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, live=True)[0]['status'], 'configuration-invalid')
            self.servers['hub'].update(url='https://example.test/mcp', clientsAgree=False)
            self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, live=True)[0]['status'], 'client-config-mismatch')
            probe.assert_not_called()

    def test_live_read_acceptance_and_revoked_key_status_are_distinct(self):
        with patch.object(mcp.mcp_native, 'probe', return_value=12):
            self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, live=True)[0],
                             {'name': 'hub', 'status': 'authenticated', 'tools': 12, 'scope': 'fresh-invocation',
                              'runningClients': 'unverified', 'otherConfigLayers': 'unverified'})
        error = mcp.mcp_native.urllib.error.HTTPError('https://example.test', 401, 'unauthorized', {}, None)
        with patch.object(mcp.mcp_native, 'probe', side_effect=error):
            self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, live=True)[0]['status'], 'unauthorized')

    def test_bearer_is_not_forwarded_on_redirect(self):
        handler = mcp.mcp_native.NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, '', {}, 'https://elsewhere.test'))

    def test_secret_source_is_required_and_bad_line_only_fails_its_server(self):
        self.secret.unlink()
        self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'})[0]['status'], 'secret-source-missing')
        self.secret.write_text('FIXTURE_KEY="unterminated\nOTHER_KEY=other\n')
        self.servers['other'] = dict(self.servers['hub'], tokenEnv='OTHER_KEY')
        rows = self.check(env={'FIXTURE_KEY': 'fixture', 'OTHER_KEY': 'other'})
        self.assertEqual([r['status'] for r in rows], ['secret-source-invalid', 'configured'])
        self.assertNotIn('unterminated', json.dumps(rows))

    def test_malformed_server_does_not_hide_next_server(self):
        self.servers = {'broken': None, **self.servers}
        rows = self.check(env={'FIXTURE_KEY': 'fixture'})
        self.assertEqual([r['status'] for r in rows], ['configuration-invalid', 'configured'])

    def test_configured_source_is_used_without_enrolled_fallback(self):
        config = {'nativeServers': self.servers, 'nativeSecretFile': str(self.secret)}
        with patch.dict(os.environ, {'FIXTURE_KEY': 'fixture'}), patch('builtins.print') as output:
            self.assertEqual(mcp.mcp_native.doctor(config), 0)
        self.assertEqual(json.loads(output.call_args.args[0])[0]['status'], 'configured')
        config['nativeSecretFile'] = str(self.secret.parent / 'missing-sops-render')
        with patch.dict(os.environ, {'FIXTURE_KEY': 'fixture'}), patch('builtins.print') as output:
            self.assertEqual(mcp.mcp_native.doctor(config), 1)
        self.assertEqual(json.loads(output.call_args.args[0])[0]['status'], 'secret-source-missing')

    def client_files(self):
        root = Path(self.temp.name)
        files = {name: str(root / filename) for name, filename in
                 [('claude', 'claude.json'), ('codexSystem', 'system.toml'), ('codexUser', 'user.toml')]}
        self.servers['hub'].update(claudeInstalled=True, claudeEnabled=True, claudeDisabled=False, codexEnabled=True)
        Path(files['claude']).write_text(json.dumps({'mcpServers': {'hub': {
            'type': 'http', 'url': self.servers['hub']['url'], 'headers': {'Authorization': 'Bearer ${FIXTURE_KEY}'}}}}))
        Path(files['codexSystem']).write_text('[mcp_servers.hub]\nurl = "https://mcp.example.test/mcp"\nbearer_token_env_var = "FIXTURE_KEY"\n')
        return files

    def test_reads_activated_claude_and_codex_user_override(self):
        files = self.client_files()
        self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, client_files=files)[0]['status'], 'configured')
        Path(files['codexUser']).write_text('[mcp_servers.hub]\nurl = "https://stale.example.test/mcp"\n')
        with patch.object(mcp.mcp_native, 'probe') as probe:
            self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, client_files=files, live=True)[0]['status'],
                             'codex-client-config-mismatch')
            probe.assert_not_called()
        Path(files['codexUser']).unlink()
        Path(files['claude']).write_text('{}')
        self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, client_files=files)[0]['status'], 'claude-activation-missing')

    def test_also_checks_a_manually_activated_claude_entry(self):
        files = self.client_files()
        self.servers['hub']['claudeEnabled'] = False
        self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, client_files=files)[0]['status'], 'configured')
        active = json.loads(Path(files['claude']).read_text())
        active['mcpServers']['hub']['url'] = 'https://stale.example.test/mcp'
        Path(files['claude']).write_text(json.dumps(active))
        self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, client_files=files)[0]['status'],
                         'claude-client-config-mismatch')

    def test_respects_disabled_claude_and_detects_stale_activation(self):
        files = self.client_files()
        self.servers['hub'].update(claudeEnabled=False, claudeDisabled=True)
        self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, client_files=files)[0]['status'],
                         'claude-disabled-server-still-activated')
        Path(files['claude']).write_text('{}')
        self.assertEqual(self.check(env={'FIXTURE_KEY': 'fixture'}, client_files=files)[0]['status'], 'configured')

    def test_codex_home_override_and_malformed_configs_are_safe(self):
        files = self.client_files()
        custom_home = Path(self.temp.name) / 'custom-codex'
        custom_home.mkdir()
        config = custom_home / 'config.toml'
        config.write_text('[mcp_servers.hub]\nenabled = false\n')
        env = {'FIXTURE_KEY': 'fixture', 'CODEX_HOME': str(custom_home)}
        self.assertEqual(self.check(env=env, client_files=files)[0]['status'], 'codex-client-config-mismatch')
        config.write_text('invalid-fixture-secret-value')
        result = self.check(env=env, client_files=files)
        self.assertEqual(result[0]['status'], 'client-config-unreadable-or-invalid')
        self.assertNotIn('fixture-secret-value', json.dumps(result))

    def test_sse_multiline_events_are_assembled_before_json_parsing(self):
        class Response(io.BytesIO):
            headers = {'Content-Type': 'text/event-stream', 'Mcp-Session-Id': 'fixture-session'}
        body = (b': heartbeat\r\ndata: {"jsonrpc":"2.0","method":"notification"}\r\n\r\n'
                b'event: message\ndata: {"jsonrpc":"2.0",\ndata: "id": 7, "result": {"tools": []}}\n\n')
        with patch.object(mcp.mcp_native.urllib.request.OpenerDirector, 'open', return_value=Response(body)):
            result, session = mcp.mcp_native.rpc(mcp.mcp_native.urllib.request.build_opener(),
                                               'https://example.test', 'fixture', {'id': 7})
        self.assertEqual(result['id'], 7)
        self.assertEqual(session, 'fixture-session')

    def test_uses_negotiated_protocol_and_session_after_initialize(self):
        replies = [({'result': {'serverInfo': {'name': 'fixture'}, 'protocolVersion': '2025-03-26'}}, 'session'),
                   (None, 'session'), ({'result': {'tools': [{'name': 'fixture'}]}}, 'session')]
        with patch.object(mcp.mcp_native, 'rpc', side_effect=replies) as rpc:
            self.assertEqual(mcp.mcp_native._probe('https://example.test', 'fixture'), 1)
        for call in rpc.call_args_list[1:]:
            self.assertEqual(call.args[-2:], ('session', '2025-03-26'))

    def test_streaming_read_and_dns_have_a_wall_clock_deadline(self):
        def never_finishes(*_args):
            time.sleep(60)
        for target in ('_probe',):
            before_children = {p.pid for p in multiprocessing.active_children()}
            started = time.monotonic()
            with patch.object(mcp.mcp_native, target, side_effect=never_finishes):
                with self.assertRaisesRegex(mcp.mcp_native.ProbeError, '^endpoint-timeout$'):
                    mcp.mcp_native.probe('https://example.test', 'fixture', timeout=0.15)
            self.assertLess(time.monotonic() - started, 1.5)
            self.assertEqual({p.pid for p in multiprocessing.active_children()}, before_children)

    def test_real_sse_trickle_cannot_extend_deadline(self):
        class Trickle(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                try:
                    for _ in range(100):
                        self.wfile.write(b': heartbeat\n\n')
                        self.wfile.flush()
                        time.sleep(0.025)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def log_message(self, *_args):
                pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Trickle)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            started = time.monotonic()
            with self.assertRaisesRegex(mcp.mcp_native.ProbeError, '^endpoint-timeout$'):
                mcp.mcp_native.probe('http://127.0.0.1:%s/mcp' % server.server_port, 'fixture', timeout=0.2)
            self.assertLess(time.monotonic() - started, 1.5)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)


class SharedMcpTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, {"HOME": str(self.root), "XDG_STATE_HOME": str(self.root / "state"),
                                           "CODEX_HOME": str(self.root / "codex")})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.cfg = {"gateway": None, "remoteVersion": "0.14.3", "servers": {
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

    def test_import_accepts_a_grant_without_expiry(self):
        source, data = self.codex_credentials()
        for name in self.cfg["servers"]:
            data[name]["expires_at"] = None
        source.write_text(json.dumps(data))
        mcp.import_codex(self.cfg)
        tokens = json.loads(mcp.cache_file(self.cfg, "personal", "tokens.json").read_text())
        self.assertNotIn("expires_at", tokens)
        self.assertEqual(tokens["refresh_token"], "example-refresh")

    def test_status_reports_presence_without_token_values(self):
        self.codex_credentials()
        mcp.import_codex(self.cfg)
        with patch("builtins.print") as output:
            mcp.status(self.cfg)
        printed = output.call_args.args[0]
        self.assertEqual(json.loads(printed), [{"name": "personal", "credentials": "stored"},
                                               {"name": "business", "credentials": "stored"}])
        self.assertNotIn("example-", printed)

    def write_tokens(self, name, **tokens):
        mcp.write_private(mcp.cache_file(self.cfg, name, "tokens.json"), {"token_type": "Bearer", **tokens})

    def statuses(self):
        with patch("builtins.print") as output:
            mcp.status(self.cfg)
        return {row["name"]: row["credentials"] for row in json.loads(output.call_args.args[0])}

    def test_connect_refuses_what_status_reports_as_login_required(self):
        self.write_tokens("personal", access_token="example-access", expires_at=int(time.time() * 1000) - 1000)
        self.assertEqual(self.statuses()["personal"], "login-required")
        with patch.object(mcp.os, "execvpe") as execvpe:
            with self.assertRaisesRegex(ValueError, "personal: login required"):
                mcp.connect(self.cfg, "personal")
        execvpe.assert_not_called()

    def test_a_grant_the_adapter_uses_without_a_browser_is_stored_and_connects(self):
        self.write_tokens("personal", access_token="example-access")
        self.write_tokens("business", access_token="example-access", refresh_token="example-refresh",
                          expires_at=int(time.time() * 1000) - 1000)
        self.assertEqual(self.statuses(), {"personal": "stored", "business": "stored"})
        with patch.object(mcp.os, "execvpe") as execvpe:
            for name in self.cfg["servers"]:
                mcp.connect(self.cfg, name)
        self.assertEqual(execvpe.call_count, 2)

    def test_partial_source_never_changes_native_credentials(self):
        source, data = self.codex_credentials()
        del data["business"]
        source.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            mcp.import_codex(self.cfg)
        self.assertEqual(json.loads(source.read_text()), data)
        self.assertFalse(mcp.auth_dir("personal").exists())


class McpProcess:
    """One stdio MCP server, spoken to with newline-delimited JSON-RPC."""

    def __init__(self, command, env, cwd):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=env, cwd=cwd)
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "test-mcp", "version": "0"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise AssertionError("server exited: " + self.process.stderr.read())
            message = json.loads(line)
            if message.get("id") == self.next_id:
                return message["result"]

    def call(self, tool, **arguments):
        result = self.request("tools/call", {"name": tool, "arguments": arguments})
        text = "".join(part.get("text", "") for part in result["content"])
        if result.get("isError"):
            raise AssertionError(f"{tool}: {text}")
        return text

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=30)
        self.process.stdout.close()
        self.process.stderr.close()


@unittest.skipUnless(os.environ.get("FLAKELAB_MCP_HEADLESS"), "needs the built headless launcher")
class HeadlessBrowserTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # The bridge's settings as the clients hand them to every server.
        self.env = dict(os.environ, HOME=self.temp.name, PLAYWRIGHT_MCP_EXTENSION="true",
                        PLAYWRIGHT_MCP_BROWSER="chrome", PLAYWRIGHT_MCP_EXECUTABLE_PATH="/nonexistent/chrome",
                        PLAYWRIGHT_BROWSERS_PATH="/nonexistent")
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SilentPage)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.url = f"http://127.0.0.1:{server.server_address[1]}/"

    def start(self):
        command = [os.environ["FLAKELAB_MCP_HEADLESS"], *shlex.split(os.environ.get("FLAKELAB_MCP_HEADLESS_ARGS", ""))]
        process = McpProcess(command, self.env, self.temp.name)
        self.addCleanup(process.close)
        return process

    def test_lists_the_tools_the_bridge_offers(self):
        tools = {tool["name"] for tool in self.start().request("tools/list", {})["tools"]}
        self.assertLessEqual({"browser_navigate", "browser_snapshot", "browser_click", "browser_take_screenshot",
                              "browser_console_messages", "browser_network_requests"}, tools)

    def test_runs_the_paired_headless_shell_despite_bridge_settings(self):
        browser = self.start()
        self.assertIn("Page Title: fixture", browser.call("browser_navigate", url=self.url))
        agent = browser.call("browser_evaluate", function="() => navigator.userAgent")
        self.assertIn("HeadlessChrome/" + os.environ["FLAKELAB_MCP_HEADLESS_VERSION"], agent)

    def test_each_server_process_has_its_own_profile(self):
        first, second = self.start(), self.start()
        for browser in (first, second):
            browser.call("browser_navigate", url=self.url)
        first.call("browser_evaluate", function="() => localStorage.setItem('owner', 'first')")
        self.assertIn("null", second.call("browser_evaluate", function="() => localStorage.getItem('owner')"))
        self.assertIn("first", first.call("browser_evaluate", function="() => localStorage.getItem('owner')"))


class SilentPage(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<title>fixture</title><button>Press</button>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class ExitCodeTest(unittest.TestCase):
    """The command as the launcher runs it: a refusal exits 2, a failure 1."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cfg = {"gateway": None, "remoteVersion": "0.14.3", "servers": {
                        "personal": {"url": "https://mail.example.test/mcp", "callbackPort": 18872}}}
        self.env = dict(os.environ, HOME=str(self.root), XDG_STATE_HOME=str(self.root / "state"),
                        CODEX_HOME=str(self.root / "codex"), FLAKELAB_MCP_CONFIG=str(self.root / "mcp.json"))

    def run_mcp(self, *args):
        (self.root / "mcp.json").write_text(json.dumps(self.cfg))
        return subprocess.run([sys.executable, str(Path(__file__).with_name("mcp.py")), *args],
                              env=self.env, capture_output=True, text=True, timeout=30)

    def assertRefused(self, result, reason):
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue(result.stderr.startswith("flakelab mcp: "), result.stderr)
        self.assertIn(reason, result.stderr)

    def codex_credentials(self):
        with patch.dict(os.environ, self.env):
            source = Path(self.env["CODEX_HOME"]) / ".credentials.json"
            mcp.write_private(source, {"personal": {
                "server_name": "personal", "server_url": self.cfg["servers"]["personal"]["url"],
                "client_id": "example-client", "access_token": "example-access", "refresh_token": "example-refresh"}})
        return source

    def test_an_unknown_account_is_refused(self):
        self.assertRefused(self.run_mcp("connect", "nobody"), "Unknown MCP account")
        self.assertRefused(self.run_mcp("connect", ""), "Unknown MCP account")
        self.assertRefused(self.run_mcp("connect", "personal"), "personal: login required")
        self.assertRefused(self.run_mcp("login", "personal", "nobody"), "Unknown MCP account")

    def test_a_worker_on_a_box_with_a_gateway_is_refused(self):
        self.cfg["gateway"] = "operator@devbox"
        self.assertRefused(self.run_mcp("_login", "personal"), "credential gateway")
        self.assertRefused(self.run_mcp("import-codex"), "original Codex credentials")
        self.assertFalse((self.root / "state").exists())

    def test_an_import_over_existing_state_is_refused_and_changes_nothing(self):
        source = self.codex_credentials()
        before = source.read_text()
        (self.root / "state/flakelab/mcp-auth/personal").mkdir(parents=True)
        self.assertRefused(self.run_mcp("import-codex"), "already exists")
        self.assertEqual(source.read_text(), before)
        (self.root / "state/flakelab/mcp-auth/personal").rmdir()
        source.with_name(source.name + ".before-shared-mcp").write_text("{}")
        self.assertRefused(self.run_mcp("import-codex"), "previous migration backup")
        self.assertEqual(source.read_text(), before)

    def test_a_login_away_from_a_desktop_is_refused(self):
        with patch.dict(os.environ, {"DISPLAY": "", "WAYLAND_DISPLAY": ""}), \
                patch.object(mcp.Path, "exists", return_value=False):
            with self.assertRaises(mcp.Refusal):
                mcp.login(self.cfg, ["personal"])

    def test_a_failure_exits_1_and_a_usage_error_2(self):
        result = self.run_mcp("import-codex")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue(result.stderr.startswith("flakelab mcp: "), result.stderr)
        result = self.run_mcp()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue(result.stderr.startswith("usage: flakelab mcp "), result.stderr)
        del self.env["FLAKELAB_MCP_CONFIG"]
        self.assertRefused(self.run_mcp("status"), "No MCP configuration")


if __name__ == "__main__":
    unittest.main()
