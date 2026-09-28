#!/usr/bin/env python3
"""One OAuth store per account and host; both agent clients use the same adapter."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qs, urlsplit


class Refusal(ValueError):
    """Nothing was changed: exit 2, as the rest of the CLI refuses."""


def configuration():
    filename = os.environ.get("FLAKELAB_MCP_CONFIG")
    if not filename:
        raise Refusal("No MCP configuration; use the installed flakelab command.")
    cfg = json.loads(Path(filename).read_text())
    ports = []
    for name, server in cfg["servers"].items():
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", name):
            raise ValueError("MCP account names must use letters, numbers, underscores or hyphens.")
        url = urlsplit(server["url"])
        if url.scheme != "https" or not url.hostname or url.username or url.fragment:
            raise ValueError(f"{name}: expected an HTTPS endpoint without credentials or fragment.")
        port = server["callbackPort"]
        if not isinstance(port, int) or not 1024 <= port <= 65535 or port in ports:
            raise ValueError("Callback ports must be distinct unprivileged TCP ports.")
        ports.append(port)
    gateway = cfg.get("gateway")
    if gateway and (gateway.startswith("-") or not re.fullmatch(r"[a-zA-Z0-9_.@:-]+", gateway)):
        raise ValueError("Invalid SSH gateway.")
    return cfg


def auth_dir(name):
    root = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    return root / "flakelab/mcp-auth" / name


def cache_file(cfg, name, suffix):
    # mcp-remote v1 hashes the URL when no resource/header overrides are supplied.
    digest = hashlib.md5(cfg["servers"][name]["url"].encode(), usedforsecurity=False).hexdigest()
    return auth_dir(name) / "mcp-remote-v1" / f"{digest}_{suffix}"


def ssh_command(cfg, args, port=None):
    command = ["ssh", "-T", "-oBatchMode=yes", "-oForwardAgent=no", "-oConnectTimeout=10"]
    if port:
        command += ["-oExitOnForwardFailure=yes", "-L", f"127.0.0.1:{port}:127.0.0.1:{port}"]
    else:
        command += ["-oClearAllForwardings=yes"]
    return command + ["--", cfg["gateway"], "flakelab", "mcp", *args]


def adapter(cfg, name, client=False):
    server = cfg["servers"][name]
    command = ["npx", "--yes", f"--package=mcp-remote@{cfg['remoteVersion']}",
               "mcp-remote-client" if client else "mcp-remote", server["url"],
               str(server["callbackPort"]), "--host", "127.0.0.1", "--auth-timeout", "300"]
    imported = auth_dir(name) / "imported-client.json"
    if imported.exists():
        command += ["--static-oauth-client-info", "@" + str(imported)]
    env = os.environ.copy()
    env["MCP_REMOTE_CONFIG_DIR"] = str(auth_dir(name))
    # No ad-hoc browser launches from an agent process on the gateway.
    env["BROWSER"] = "false"
    env.pop("DEBUG", None)
    return command, env


def status(cfg):
    if cfg.get("gateway"):
        return subprocess.call(ssh_command(cfg, ["status"]))
    rows = []
    for name in cfg["servers"]:
        try:
            tokens = json.loads(cache_file(cfg, name, "tokens.json").read_text())
            usable = bool(tokens.get("refresh_token") or
                          (tokens.get("access_token") and tokens.get("expires_at", 0) > time.time() * 1000))
        except (OSError, ValueError):
            usable = False
        rows.append({"name": name, "credentials": "stored" if usable else "login-required"})
    print(json.dumps(rows))
    return 0


def connect(cfg, name):
    if cfg.get("gateway"):
        command = ssh_command(cfg, ["connect", name])
        os.execvp(command[0], command)
    if not cache_file(cfg, name, "tokens.json").is_file():
        raise ValueError(f"{name}: login required. Run 'flakelab mcp login {name}' on your desktop.")
    command, env = adapter(cfg, name)
    os.execvpe(command[0], command, env)


def authorization_url(line, port):
    """Only relay an OAuth browser URL for our forwarded loopback callback."""
    for candidate in re.findall(r"https://[^\s]+", line):
        parsed = urlsplit(candidate)
        query = parse_qs(parsed.query)
        callback = query.get("redirect_uri", [""])[0]
        if (parsed.hostname and not parsed.username and query.get("state") and
                callback == f"http://127.0.0.1:{port}/oauth/callback"):
            return candidate
    return None


def event(kind, **values):
    print(json.dumps({"event": kind, **values}), flush=True)


def login_local(cfg, name, fresh=False):
    if cfg.get("gateway"):
        raise Refusal("The login worker must run on the credential gateway.")
    directory = auth_dir(name)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    if fresh:
        # Explicit reauthorization drops the imported registration too: its original
        # client's redirect URI may differ from our fixed callback port.
        for path in [directory / "imported-client.json",
                     cache_file(cfg, name, "client_info.json"), cache_file(cfg, name, "tokens.json")]:
            path.unlink(missing_ok=True)
    command, env = adapter(cfg, name, client=True)
    process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = b""
    deadline = time.monotonic() + 330
    connected = False
    try:
        while time.monotonic() < deadline:
            ready = selector.select(timeout=1)
            if not ready:
                continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                raw, buffer = buffer.split(b"\n", 1)
                line = raw.decode(errors="replace")
                url = authorization_url(line, cfg["servers"][name]["callbackPort"])
                if url:
                    event("authorize", name=name, url=url)
                if "Connected successfully!" in line:
                    connected = True
        try:
            code = process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            code = 1
        success = code == 0 and connected
        event("complete" if success else "failed", name=name)
        return 0 if success else 1
    finally:
        selector.close()
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


def login(cfg, names, fresh=False):
    # Launch from WSL: SSH carries both the login events and the callback tunnel.
    # The authorization URL never needs to be copied out of SSH or tmux.
    if not cfg.get("gateway") and not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY") or Path("/mnt/c/Windows").exists()):
        raise Refusal("Run 'flakelab mcp login' on a desktop; it opens the browser and forwards callbacks automatically.")
    opener = shutil.which("xdg-open")
    if not opener:
        raise ValueError("xdg-open is required to open the desktop browser.")
    for name in names:
        args = ["_login", name] + (["--fresh"] if fresh else [])
        command = (ssh_command(cfg, args, cfg["servers"][name]["callbackPort"])
                   if cfg.get("gateway") else [sys.executable, __file__, *args])
        print(f"Checking {name}…", flush=True)
        with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as process:
            complete = False
            for line in process.stdout:
                try:
                    result = json.loads(line)
                except ValueError:
                    continue
                if result.get("event") == "authorize":
                    url = authorization_url(result.get("url", ""), cfg["servers"][name]["callbackPort"])
                    if not url:
                        process.terminate()
                        raise ValueError("Rejected an unexpected authorization callback.")
                    subprocess.run([opener, url], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                elif result.get("event") == "complete":
                    complete = True
            if process.wait() != 0 or not complete:
                raise ValueError(f"{name}: login failed; use --fresh if its previous authorization was revoked.")
        print(f"{name}: ready for Claude and Codex on every configured machine.")
    return 0


def write_private(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def import_codex(cfg):
    """Explicit one-time move, after stopping clients using native Codex OAuth."""
    if cfg.get("gateway"):
        raise Refusal("Import must run on the host holding the original Codex credentials.")
    source = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / ".credentials.json"
    data = json.loads(source.read_text())
    selected = []
    for name, server in cfg["servers"].items():
        matches = [(k, v) for k, v in data.items() if isinstance(v, dict) and
                   v.get("server_name") == name and v.get("server_url") == server["url"]]
        if len(matches) != 1:
            raise ValueError(f"{name}: expected exactly one matching native Codex credential.")
        if auth_dir(name).exists():
            raise Refusal(f"{name}: shared auth directory already exists; refusing to overwrite it.")
        key, value = matches[0]
        if not value.get("client_id") or not value.get("refresh_token") or not value.get("access_token"):
            raise ValueError(f"{name}: credential lacks a client ID or token.")
        selected.append((name, key, value))
    # Keep a private rollback copy; never use it concurrently with the new owner.
    backup = source.with_name(source.name + ".before-shared-mcp")
    if backup.exists():
        raise Refusal("A previous migration backup exists; inspect it before retrying.")
    write_private(backup, data)
    for name, key, value in selected:
        write_private(auth_dir(name) / "imported-client.json",
                      {"client_id": value["client_id"], "token_endpoint_auth_method": "none"})
        scopes = value.get("scopes") or []
        tokens = {"access_token": value["access_token"], "refresh_token": value["refresh_token"],
                  "token_type": "Bearer", "scope": " ".join(scopes) if isinstance(scopes, list) else scopes}
        # Codex stores no expiry for a token its provider issued without one.
        expires_at = value.get("expires_at")
        if isinstance(expires_at, (int, float)):
            tokens["expires_at"] = expires_at
            tokens["expires_in"] = max(0, int((expires_at - time.time() * 1000) / 1000))
        write_private(cache_file(cfg, name, "tokens.json"), tokens)
        del data[key]
    write_private(source, data)
    print(f"Moved {len(selected)} authorizations to the shared adapter. Restart agent clients before using them.")
    return 0


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(prog="flakelab mcp", description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("status", help="report credential presence without exposing tokens")
    sub.add_parser("import-codex", help="move native Codex grants; stop agent clients first")
    for action in ["connect", "_login"]:
        child = sub.add_parser(action)
        child.add_argument("name")
        if action == "_login":
            child.add_argument("--fresh", action="store_true")
    child = sub.add_parser("login", help="open desktop browser and forward callbacks over SSH")
    child.add_argument("names", nargs="*")
    child.add_argument("--fresh", action="store_true", help="discard old grants and register again")
    args = parser.parse_args()
    cfg = configuration()
    if getattr(args, "name", None) and args.name not in cfg["servers"]:
        raise Refusal("Unknown MCP account.")
    if args.action == "status":
        return status(cfg)
    if args.action == "connect":
        return connect(cfg, args.name)
    if args.action == "_login":
        return login_local(cfg, args.name, args.fresh)
    if args.action == "import-codex":
        return import_codex(cfg)
    names = args.names or list(cfg["servers"])
    if any(name not in cfg["servers"] for name in names):
        raise Refusal("Unknown MCP account.")
    return login(cfg, names, args.fresh)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Refusal as error:
        print(f"flakelab mcp: {error}", file=sys.stderr)
        sys.exit(2)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"flakelab mcp: {error}", file=sys.stderr)
        sys.exit(1)
