"""Bounded, credential-safe checks of a fresh native HTTP MCP invocation."""
import json
import multiprocessing
import os
from pathlib import Path
import re
import shlex
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request


MAX_RESPONSE = 1024 * 1024
PROTOCOLS = {"2024-11-05", "2025-03-26", "2025-06-18"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


class ProbeError(ValueError):
    """Only a fixed status, never response content or a credential."""


def rpc(opener, url, token, payload, session=None, protocol=None):
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}
    if protocol:
        headers["MCP-Protocol-Version"] = protocol
    if session:
        headers["Mcp-Session-Id"] = session
    request = urllib.request.Request(url, json.dumps(payload).encode(), headers)
    with opener.open(request, timeout=10) as response:
        next_session = response.headers.get("Mcp-Session-Id") or session
        if "id" not in payload:
            return None, next_session
        if "text/event-stream" in response.headers.get("Content-Type", ""):
            size, data = 0, []
            while size <= MAX_RESPONSE:
                line = response.readline(MAX_RESPONSE + 1 - size)
                size += len(line)
                if not line or size > MAX_RESPONSE:
                    break
                line = line.rstrip(b"\r\n")
                if not line:
                    if data:
                        result = json.loads(b"\n".join(data))
                        if isinstance(result, dict) and result.get("id") == payload["id"]:
                            return result, next_session
                    data = []
                elif line.startswith(b"data:"):
                    value = line[5:]
                    data.append(value[1:] if value.startswith(b" ") else value)
            raise ValueError("Missing bounded RPC result")
        data = response.read(MAX_RESPONSE + 1)
        if len(data) > MAX_RESPONSE:
            raise ValueError("Oversized RPC result")
        result = json.loads(data)
        if not isinstance(result, dict) or result.get("id") != payload["id"]:
            raise ValueError("Wrong RPC response ID")
        return result, next_session


def _probe(url, token):
    opener = urllib.request.build_opener(NoRedirect())
    result, session = rpc(opener, url, token, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "flakelab-doctor", "version": "1"}}})
    initialized = result.get("result", {})
    protocol = initialized.get("protocolVersion")
    if result.get("error") or not initialized.get("serverInfo") or protocol not in PROTOCOLS:
        raise ValueError("Initialization failed")
    rpc(opener, url, token, {"jsonrpc": "2.0", "method": "notifications/initialized"}, session, protocol)
    result, _ = rpc(opener, url, token, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, session, protocol)
    tools = result.get("result", {}).get("tools")
    if result.get("error") or not isinstance(tools, list) or not tools:
        raise ValueError("No usable tools")
    return len(tools)


def _probe_worker(connection, url, token):
    try:
        connection.send(("authenticated", _probe(url, token)))
    except urllib.error.HTTPError as error:
        connection.send(("unauthorized" if error.code in (401, 403) else "endpoint-unavailable", None))
    except Exception:
        # Never transport exception strings: they may contain server data or headers.
        connection.send(("endpoint-unavailable", None))
    finally:
        connection.close()


def probe(url, token, timeout=15):
    # Socket timeouts only bound inactivity. A separate process also bounds DNS,
    # response headers and an endless stream of bytes that keeps a socket active.
    # fork is supported on both flakelab targets, Linux and macOS; no secret argv.
    context = multiprocessing.get_context("fork")
    receiver, sender = context.Pipe(duplex=False)
    worker = context.Process(target=_probe_worker, args=(sender, url, token), daemon=True)
    deadline = time.monotonic() + timeout
    worker.start()
    sender.close()
    try:
        if not receiver.poll(max(0, deadline - time.monotonic())):
            raise ProbeError("endpoint-timeout")
        try:
            status, count = receiver.recv()
        except EOFError:
            raise ProbeError("endpoint-unavailable") from None
        if status != "authenticated":
            raise ProbeError(status)
        return count
    finally:
        receiver.close()
        if worker.is_alive():
            worker.terminate()
        worker.join(timeout=0.2)
        if worker.is_alive():
            worker.kill()
            worker.join(timeout=0.2)
        if not worker.is_alive():
            worker.close()


def _read_object(path, *, toml=False):
    with Path(path).open("rb") as source:
        data = source.read(MAX_RESPONSE + 1)
    if len(data) > MAX_RESPONSE:
        raise ValueError("Oversized configuration")
    result = tomllib.loads(data.decode()) if toml else json.loads(data)
    if not isinstance(result, dict):
        raise ValueError("Configuration is not an object")
    return result


def _client_status(name, server, files, env):
    """Inspect only activated/user/system files; do not claim full precedence."""
    if not files:
        return None
    try:
        if server.get("claudeInstalled"):
            if env.get("CLAUDE_CONFIG_DIR"):
                return "claude-config-dir-unverified"
            try:
                claude = _read_object(files["claude"])
            except FileNotFoundError:
                claude = {}
            active = claude.get("mcpServers", {}).get(name)
            if active is not None and server.get("claudeDisabled"):
                return "claude-disabled-server-still-activated"
            if server.get("claudeEnabled") and not active:
                return "claude-activation-missing"
            if active is not None:
                if (active.get("url") != server["url"] or active.get("type") != "http"
                        or active.get("headers", {}).get("Authorization") != "Bearer ${" + server["tokenEnv"] + "}"):
                    return "claude-client-config-mismatch"
                if name in claude.get("disabledMcpServers", []):
                    return "claude-server-disabled"
        if server.get("codexEnabled", True):
            effective = {}
            codex_home = env.get("CODEX_HOME")
            user_config = Path(codex_home) / "config.toml" if codex_home else files["codexUser"]
            for path in (files["codexSystem"], user_config):
                try:
                    config = _read_object(path, toml=True)
                except FileNotFoundError:
                    continue
                override = config.get("mcp_servers", {}).get(name, {})
                if not isinstance(override, dict):
                    return "codex-client-config-invalid"
                effective.update(override)
            if not effective:
                return "codex-activation-missing"
            if (effective.get("url") != server["url"] or effective.get("bearer_token_env_var") != server["tokenEnv"]
                    or effective.get("enabled") is False or effective.get("command")
                    or any(key.lower() == "authorization" for field in ("http_headers", "env_http_headers")
                           for key in effective.get(field, {}))):
                return "codex-client-config-mismatch"
    except (OSError, ValueError, TypeError, AttributeError, KeyError):
        return "client-config-unreadable-or-invalid"
    return None


def _secrets(secret_file, names):
    stored, invalid = {}, set()
    try:
        with Path(secret_file).open() as source:
            content = source.read(MAX_RESPONSE + 1)
        if len(content) > MAX_RESPONSE:
            return {}, set(), "secret-source-invalid"
        for line in content.replace("\r", "").splitlines():
            line = line.strip().removeprefix("export ")
            key, separator, value = line.partition("=")
            if separator and key in names:
                try:
                    fields = shlex.split(value, comments=True)
                except ValueError:
                    invalid.add(key)
                    continue
                if len(fields) != 1 or any(char in value for char in ("$", "`")):
                    invalid.add(key)
                else:
                    stored[key] = fields[0]
        return stored, invalid, None
    except FileNotFoundError:
        return {}, set(), "secret-source-missing"
    except (OSError, ValueError):
        return {}, set(), "secret-source-unreadable"


def check(servers, live=False, env=None, secret_file="/run/secrets/tyc-env", client_files=None):
    if not servers:
        return []
    env = os.environ if env is None else env
    names = {s.get("tokenEnv") for s in servers.values() if isinstance(s, dict) and isinstance(s.get("tokenEnv"), str)}
    stored, invalid, source_error = _secrets(secret_file, names)
    results = []
    for name, server in servers.items():
        row = {"name": name, "status": "configuration-invalid", "scope": "fresh-invocation",
               "runningClients": "unverified", "otherConfigLayers": "unverified"}
        results.append(row)
        try:
            url = urllib.parse.urlsplit(server.get("url", ""))
            key = server.get("tokenEnv", "")
            if (url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment
                    or url.port == 0 or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key)):
                continue
            if not server.get("clientsAgree", True):
                row["status"] = "client-config-mismatch"
                continue
            client_error = _client_status(name, server, client_files, env)
            if client_error:
                row["status"] = client_error
                continue
            token = env.get(key, "")
            if not token or "${" in token:
                row["status"] = "credential-missing-from-environment"
                continue
            if source_error or key in invalid or not stored.get(key):
                row["status"] = source_error or ("secret-source-invalid" if key in invalid else "credential-missing-from-source")
                continue
            if token != stored[key]:
                row["status"] = "fresh-environment-source-mismatch"
                continue
            row["status"] = "configured"
            if live:
                row["tools"] = probe(server["url"], token)
                row["status"] = "authenticated"
        except ProbeError as error:
            row["status"] = str(error)
        except urllib.error.HTTPError as error:
            row["status"] = "unauthorized" if error.code in (401, 403) else "endpoint-unavailable"
        except (OSError, ValueError, TypeError, AttributeError):
            row["status"] = "endpoint-unavailable" if row["status"] == "configured" else "configuration-invalid"
    return results


def doctor(config, live=False):
    results = check(config.get("nativeServers", {}), live, secret_file=config.get("nativeSecretFile", "/run/secrets/tyc-env"),
                    client_files=config.get("nativeClientFiles"))
    print(json.dumps(results))
    return int(any(r["status"] not in {"configured", "authenticated"} for r in results))
