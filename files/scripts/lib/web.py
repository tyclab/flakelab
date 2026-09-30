"""flakelab web — the dashboard behind `flakelab web` (remote-sessions.md).

One process, the standard library only: a threaded HTTP server that serves
the page (files/config/web/index.html) and a small JSON API over the two
scripts that already know the state, `accounts` and `claude-sessions`. It
never reads a token file of a tool, never touches the network itself, and
does nothing the CLI could not: every write is one CLI call, so the CLI's
own locks, refusals and exit codes hold.

Bind and token: 127.0.0.1:8321 unless told otherwise, never every interface;
every /api call but /api/health needs `Authorization: Bearer <token>`
matching the token file (0600, generated on first start when absent). The
file is read again whenever it changes, so `flakelab web --rotate-token`
takes effect on a running server. The page is static and served without the
token; it asks for the token once and keeps it in the browser. A request
whose Host is not this server's address is refused (421): a page elsewhere
that rebinds a name to this address gets nothing.

The terminal: with FLAKELAB_WEB_TERMINAL_SOCKET set, ttyd listens on that
Unix socket with no credential of its own and this server is its only door.
POST /api/terminal, with the bearer, issues a session cookie scoped to
/terminal (HttpOnly, SameSite=Strict, 12 hours); /terminal/ and everything
under it is then tunnelled to the socket as it came, WebSocket included. A
token rotation ends every session.

Environment (set by the zsh wrapper):
  FLAKELAB_WEB_BIND, FLAKELAB_WEB_PORT      address and port
  FLAKELAB_WEB_TOKEN_FILE                   the token file
  FLAKELAB_WEB_STATIC                       the directory holding index.html
  FLAKELAB_WEB_ACCOUNTS, FLAKELAB_WEB_SESSIONS   the two commands
  FLAKELAB_WEB_TERMINAL_SOCKET              optional: ttyd's Unix socket
  FLAKELAB_WEB_LOGO                         optional: an image served at /logo, the
                                            page's heading mark and tab icon
  FLAKELAB_WEB_TIMEOUT                      seconds per CLI call (default 60)

Without the token: GET / (the page), GET /logo (the configured image, 404
without one), GET /api/health {ok, logo}.

API (all JSON, the bearer required):
  GET  /api/state                {accounts, status, config, events, sessions, terminal}
                                 (config: accounts config --json; events: accounts log --json)
  POST /api/fetch                accounts --fetch --json         -> {accounts}
  POST /api/switch {entry}       accounts switch <entry> [--force]
  POST /api/auto {dryRun}        accounts auto --once --json [--dry-run] -> {events}
  POST /api/config {key, value}  accounts config set <key> <value>
  POST /api/config {key, unset: true} | {all: true, unset: true}
                                 accounts config unset <key> | --all
  POST /api/sessions/start {tool, dir, args?}   claude-sessions --start <tool> <dir> --detach
  POST /api/terminal             a session cookie for /terminal/ (204)
Every CLI result comes back as {ok, code, stdout, stderr} beside the parsed
document where there is one.
"""

import hmac
import ipaddress
import json
import os
import secrets
import selectors
import shlex
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BIND = os.environ.get("FLAKELAB_WEB_BIND", "127.0.0.1")
PORT = int(os.environ.get("FLAKELAB_WEB_PORT", "8321"))
TOKEN_FILE = Path(
    os.environ.get(
        "FLAKELAB_WEB_TOKEN_FILE",
        os.path.join(os.path.expanduser("~"), ".local/state/flakelab/web/token"),
    )
)
STATIC = Path(
    os.environ.get("FLAKELAB_WEB_STATIC", os.path.dirname(os.path.abspath(__file__)))
)
ACCOUNTS = os.environ.get("FLAKELAB_WEB_ACCOUNTS", "accounts")
SESSIONS = os.environ.get("FLAKELAB_WEB_SESSIONS", "claude-sessions")
TERMINAL_SOCKET = os.environ.get("FLAKELAB_WEB_TERMINAL_SOCKET", "")
LOGO = os.environ.get("FLAKELAB_WEB_LOGO", "")
# Any other suffix is refused at start: a stray path never serves as the mark.
LOGO_TYPES = {
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
}
TIMEOUT = int(os.environ.get("FLAKELAB_WEB_TIMEOUT", "60"))
TOOLS = ("claude", "codex", "kiro")
# The engine's last events the page shows.
EVENTS = 30
# A connection that sends nothing for this long is dropped: an idle
# connection holds a thread, and a peer on the tunnel can open any number.
IDLE_S = 30
COOKIE = "flakelab_terminal"
SESSION_S = 12 * 3600


def bind_refusal(addr: str):
    """Why ADDR must not be bound, or None: the unspecified address in any
    spelling ("0.0.0.0", "::", "0", a name that resolves to it) is every
    interface."""
    try:
        ips = [ipaddress.ip_address(addr)]
    except ValueError:
        try:
            ips = [ipaddress.ip_address(i[4][0]) for i in socket.getaddrinfo(addr, None)]
        except (OSError, ValueError):
            return f"cannot resolve {addr}"
    if not ips or any(ip.is_unspecified for ip in ips):
        return "refusing to bind every interface; name the WireGuard address"
    return None


class Token:
    """The token as the file holds it now, and the terminal sessions issued
    against it. The file is read again when it changes (a rotation), and
    every session goes with the old token."""

    def __init__(self):
        self.lock = threading.Lock()
        self.value = ""
        self.stamp = None
        self.sessions = {}

    def _make(self) -> str:
        TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(TOKEN_FILE.parent, 0o700)
        tok = secrets.token_urlsafe(32)
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(tok + "\n")
        os.chmod(TOKEN_FILE, 0o600)
        return tok

    def current(self) -> str:
        with self.lock:
            try:
                st = TOKEN_FILE.stat()
                stamp = (st.st_mtime_ns, st.st_ino, st.st_size)
                tok = TOKEN_FILE.read_text().strip() if stamp != self.stamp else self.value
            except OSError:
                tok, stamp = "", None
            if not tok:
                tok = self._make()
                st = TOKEN_FILE.stat()
                stamp = (st.st_mtime_ns, st.st_ino, st.st_size)
            if stamp != self.stamp:
                self.stamp, self.value = stamp, tok
                self.sessions.clear()
            return self.value

    def check(self, presented: str) -> bool:
        return hmac.compare_digest(presented, self.current())

    def open_session(self) -> str:
        self.current()
        sid = secrets.token_urlsafe(32)
        with self.lock:
            now = time.monotonic()
            self.sessions = {k: v for k, v in self.sessions.items() if v > now}
            self.sessions[sid] = now + SESSION_S
        return sid

    def has_session(self, sid: str) -> bool:
        self.current()
        with self.lock:
            now = time.monotonic()
            for k, exp in self.sessions.items():
                if hmac.compare_digest(k, sid) and exp > now:
                    return True
        return False


TOKEN = Token()


def run(argv, stdin_text=None):
    """One CLI call; never raises, the outcome is the document."""
    try:
        p = subprocess.run(
            argv,
            input=stdin_text,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            stdin=None if stdin_text is not None else subprocess.DEVNULL,
        )
        return {
            "ok": p.returncode == 0,
            "code": p.returncode,
            "stdout": p.stdout,
            "stderr": p.stderr,
        }
    except FileNotFoundError:
        return {
            "ok": False,
            "code": 127,
            "stdout": "",
            "stderr": f"{argv[0]}: not found",
        }
    except subprocess.TimeoutExpired:
        return {
            "ok": False,
            "code": 124,
            "stdout": "",
            "stderr": f"{shlex.join(argv)}: timed out after {TIMEOUT}s",
        }


def parse(text, default):
    try:
        return json.loads(text) if text.strip() else default
    except ValueError:
        return default


def json_lines(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            out.append({"event": "text", "line": line})
    return out


def state():
    # Read-only calls, none takes the store's lock: side by side, so a
    # refresh costs the slowest of them.
    with ThreadPoolExecutor(5) as pool:
        acc, st, cfg, ev, se = pool.map(
            run,
            [
                [ACCOUNTS, "--json"],
                [ACCOUNTS, "status", "--json"],
                [ACCOUNTS, "config", "--json"],
                [ACCOUNTS, "log", "--json", "--lines", str(EVENTS)],
                [SESSIONS, "--json"],
            ],
        )
    return {
        "accounts": parse(acc["stdout"], {}),
        "status": parse(st["stdout"], {}),
        "config": parse(cfg["stdout"], {}),
        "events": json_lines(ev["stdout"]),
        "sessions": parse(se["stdout"], []),
        "terminal": bool(TERMINAL_SOCKET),
        "calls": {"accounts": acc, "status": st, "config": cfg, "events": ev, "sessions": se},
    }


def config_argv(doc):
    """The `accounts config` call a POST /api/config body asks for, or the
    reason it is refused. The CLI validates the key and the value; this only
    keeps an option out of the key and turns a JSON value into its text."""
    key = doc.get("key")
    if doc.get("unset") is True:
        if doc.get("all") is True:
            return [ACCOUNTS, "config", "unset", "--all"], None
        if isinstance(key, str) and key and not key.startswith("-"):
            return [ACCOUNTS, "config", "unset", key], None
        return None, "key is required (or all: true)"
    if not isinstance(key, str) or not key or key.startswith("-"):
        return None, "key is required"
    value = doc.get("value")
    if isinstance(value, bool):
        text = "true" if value else "false"
    elif isinstance(value, int):
        text = str(value)
    elif isinstance(value, float) and value.is_integer():
        text = str(int(value))
    elif isinstance(value, str) and value.strip():
        text = value.strip()
    else:
        return None, "value must be a string, an integer or a boolean"
    return [ACCOUNTS, "config", "set", key, text], None


class Handler(BaseHTTPRequestHandler):
    server_version = "flakelab-web/1.0"
    timeout = IDLE_S
    # Unbuffered reads: after the headers nothing of the client's stream sits
    # in a buffer, so the tunnel hands ttyd every byte that follows.
    rbufsize = 0

    # --- plumbing -----------------------------------------------------------
    def log_message(
        self, fmt, *args
    ):  # one line per request on stderr, no client noise
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send_json(self, code, doc, extra=()):
        body = json.dumps(doc).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def host_ok(self) -> bool:
        """The Host header names this server: its address, or loopback when
        it is bound there. Anything else is a name a page elsewhere pointed
        here (DNS rebinding) and gets nothing."""
        host = self.headers.get("Host", "").strip().lower()
        if host.startswith("["):
            host = host[1 : host.find("]")] if "]" in host else host
        else:
            host = host.rsplit(":", 1)[0] if host.count(":") == 1 else host
        bound = self.server.server_address[0].lower()
        allowed = {BIND.lower(), bound}
        if bound in ("127.0.0.1", "::1") or BIND.lower() == "localhost":
            allowed |= {"localhost", "127.0.0.1", "::1"}
        return host in allowed

    def authed(self) -> bool:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        return TOKEN.check(auth[7:].strip())

    def terminal_session(self) -> bool:
        jar = cookies.SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie", ""))
        except cookies.CookieError:
            return False
        morsel = jar.get(COOKIE)
        return morsel is not None and TOKEN.has_session(morsel.value)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        raw = self.rfile.read(min(n, 65536))
        try:
            doc = json.loads(raw.decode() or "{}")
        except ValueError:
            return None
        return doc if isinstance(doc, dict) else None

    # --- the terminal -------------------------------------------------------
    def is_terminal(self, path) -> bool:
        return path == "/terminal" or path.startswith("/terminal/")

    def tunnel(self):
        """This request, then the bytes both ways, to ttyd on its socket."""
        up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            up.settimeout(5)
            up.connect(TERMINAL_SOCKET)
        except OSError:
            up.close()
            self.send_json(502, {"error": "the terminal is not running"})
            return
        upgrade = "upgrade" in self.headers.get("Connection", "").lower()
        head = [f"{self.command} {self.path} {self.request_version}"]
        for k, v in self.headers.items():
            if k.lower() == "cookie":
                continue  # the session is this server's business
            if k.lower() == "connection" and not upgrade:
                continue
            head.append(f"{k}: {v}")
        if not upgrade:
            head.append("Connection: close")
        head.append("")
        head.append("")
        try:
            up.sendall("\r\n".join(head).encode("latin-1"))
        except (OSError, UnicodeEncodeError):
            up.close()
            self.send_json(502, {"error": "the terminal did not take the request"})
            return
        client = self.connection
        client.settimeout(None)
        up.settimeout(None)
        sel = selectors.DefaultSelector()
        sel.register(client, selectors.EVENT_READ, up)
        sel.register(up, selectors.EVENT_READ, client)
        try:
            while True:
                ready = sel.select()
                done = False
                for key, _ in ready:
                    src, dst = key.fileobj, key.data
                    assert isinstance(src, socket.socket)
                    try:
                        data = src.recv(65536)
                    except OSError:
                        data = b""
                    if not data:
                        done = True
                        break
                    try:
                        dst.sendall(data)
                    except OSError:
                        done = True
                        break
                if done:
                    break
        finally:
            sel.close()
            up.close()
            self.close_connection = True

    # --- routes -------------------------------------------------------------
    def do_GET(self):
        if not self.host_ok():
            self.send_json(421, {"error": "unexpected Host"})
            return
        path = self.path.split("?", 1)[0]
        if self.is_terminal(path):
            if not TERMINAL_SOCKET:
                self.send_json(404, {"error": "no terminal is configured"})
            elif not self.terminal_session():
                self.send_json(401, {"error": "a terminal session is required: open it from the dashboard"})
            else:
                self.tunnel()
            return
        if path in ("/", "/index.html"):
            page = STATIC / "index.html"
            if not page.is_file():
                self.send_json(500, {"error": "index.html is missing"})
                return
            data = page.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return
        if path == "/api/health":
            self.send_json(200, {"ok": True, "logo": bool(LOGO)})
            return
        if path == "/logo":
            # Static like the page: no token, cacheable, only when configured.
            logo = Path(LOGO) if LOGO else None
            if logo is None or not logo.is_file():
                self.send_json(404, {"error": "no logo is configured"})
                return
            data = logo.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", LOGO_TYPES[logo.suffix.lower()])
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "max-age=3600")
            self.end_headers()
            self.wfile.write(data)
            return
        if not path.startswith("/api/"):
            self.send_json(404, {"error": "not found"})
            return
        if not self.authed():
            self.send_json(401, {"error": "a bearer token is required"})
            return
        if path == "/api/state":
            self.send_json(200, state())
            return
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self.host_ok():
            self.send_json(421, {"error": "unexpected Host"})
            return
        path = self.path.split("?", 1)[0]
        if self.is_terminal(path):
            if not TERMINAL_SOCKET:
                self.send_json(404, {"error": "no terminal is configured"})
            elif not self.terminal_session():
                self.send_json(401, {"error": "a terminal session is required: open it from the dashboard"})
            else:
                self.tunnel()
            return
        if not path.startswith("/api/"):
            self.send_json(404, {"error": "not found"})
            return
        if not self.authed():
            self.send_json(401, {"error": "a bearer token is required"})
            return
        if path == "/api/terminal":
            if not TERMINAL_SOCKET:
                self.send_json(404, {"error": "no terminal is configured"})
                return
            sid = TOKEN.open_session()
            cookie = f"{COOKIE}={sid}; Path=/terminal; HttpOnly; SameSite=Strict; Max-Age={SESSION_S}"
            self.send_json(200, {"ok": True, "terminal": "/terminal/"}, [("Set-Cookie", cookie)])
            return
        doc = self.body()
        if doc is None:
            self.send_json(400, {"error": "the body must be a JSON object"})
            return
        if path == "/api/fetch":
            r = run([ACCOUNTS, "--fetch", "--json"])
            self.send_json(
                200 if r["ok"] else 502, {"call": r, "accounts": parse(r["stdout"], {})}
            )
            return
        if path == "/api/switch":
            entry = str(doc.get("entry", "")).strip()
            if not entry or entry.startswith("-"):
                self.send_json(
                    400, {"error": "entry is required (an id, an alias or a label)"}
                )
                return
            argv = [ACCOUNTS, "switch", entry]
            if doc.get("force") is True:
                argv.append("--force")
            r = run(argv)
            self.send_json(
                200 if r["ok"] else (409 if r["code"] == 2 else 502), {"call": r}
            )
            return
        if path == "/api/auto":
            argv = [ACCOUNTS, "auto", "--once", "--json"]
            if doc.get("dryRun", True) is not False:
                argv.append("--dry-run")
            tool = str(doc.get("tool", "")).strip()
            if tool:
                if tool not in TOOLS:
                    self.send_json(
                        400, {"error": "tool must be one of " + ", ".join(TOOLS)}
                    )
                    return
                argv += ["--tool", tool]
            r = run(argv)
            self.send_json(
                200 if r["ok"] else 502, {"call": r, "events": json_lines(r["stdout"])}
            )
            return
        if path == "/api/config":
            argv, why = config_argv(doc)
            if argv is None:
                self.send_json(400, {"error": why})
                return
            r = run(argv)
            self.send_json(
                200 if r["ok"] else (409 if r["code"] == 2 else 502), {"call": r}
            )
            return
        if path == "/api/sessions/start":
            tool = str(doc.get("tool", "")).strip()
            d = str(doc.get("dir", "")).strip()
            if tool not in TOOLS:
                self.send_json(
                    400, {"error": "tool must be one of " + ", ".join(TOOLS)}
                )
                return
            if not d or not os.path.isdir(os.path.expanduser(d)):
                self.send_json(400, {"error": "dir must be an existing directory"})
                return
            args = doc.get("args", [])
            if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
                self.send_json(400, {"error": "args must be a list of strings"})
                return
            argv = [SESSIONS, "--start", tool, os.path.expanduser(d), "--detach"]
            if args:
                argv += ["--"] + args
            r = run(argv)
            self.send_json(200 if r["ok"] else 502, {"call": r})
            return
        self.send_json(404, {"error": "not found"})


def main():
    if LOGO and Path(LOGO).suffix.lower() not in LOGO_TYPES:
        sys.stderr.write(
            f"flakelab web: refusing FLAKELAB_WEB_LOGO {LOGO}: not an image type ({', '.join(sorted(LOGO_TYPES))})\n"
        )
        sys.exit(2)
    refusal = bind_refusal(BIND)
    if refusal:
        sys.stderr.write(f"flakelab web: {refusal}\n")
        sys.exit(2)
    TOKEN.current()
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    httpd.daemon_threads = True
    sys.stderr.write(
        f"flakelab web: http://{BIND}:{httpd.server_address[1]}/ (token: {TOKEN_FILE})\n"
    )
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
