"""flakelab web — the dashboard behind `flakelab web` (remote-sessions.md).

One process, the standard library only: a threaded HTTP server that serves
the page (files/config/web/index.html) and a small JSON API over the two
scripts that already know the state, `accounts` and `claude-sessions`. It
never reads a token file of a tool, never touches the network itself, and
does nothing the CLI could not: every write is one CLI call, so the CLI's
own locks, refusals and exit codes hold.

Bind and token: 127.0.0.1:8321 unless told otherwise; every /api call needs
`Authorization: Bearer <token>` matching the token file (0600, generated on
first start when absent). The page is static and served without the token;
it asks for the token once and keeps it in the browser.

Environment (set by the zsh wrapper):
  FLAKELAB_WEB_BIND, FLAKELAB_WEB_PORT      address and port
  FLAKELAB_WEB_TOKEN_FILE                   the token file
  FLAKELAB_WEB_STATIC                       the directory holding index.html
  FLAKELAB_WEB_ACCOUNTS, FLAKELAB_WEB_SESSIONS   the two commands
  FLAKELAB_WEB_TERMINAL_URL                 optional: the browser terminal to link
  FLAKELAB_WEB_TIMEOUT                      seconds per CLI call (default 60)

API (all JSON):
  GET  /api/state                {accounts, status, sessions, terminal}
  POST /api/fetch                accounts --fetch --json         -> {accounts}
  POST /api/switch {entry}       accounts switch <entry> [--force]
  POST /api/auto {dryRun}        accounts auto --once --json [--dry-run] -> {events}
  POST /api/sessions/start {tool, dir, args?}   claude-sessions --start <tool> <dir> --detach
Every CLI result comes back as {ok, code, stdout, stderr} beside the parsed
document where there is one.
"""

import hmac
import json
import os
import secrets
import shlex
import subprocess
import sys
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
TERMINAL_URL = os.environ.get("FLAKELAB_WEB_TERMINAL_URL", "")
TIMEOUT = int(os.environ.get("FLAKELAB_WEB_TIMEOUT", "60"))
TOOLS = ("claude", "codex", "kiro")


def load_token() -> str:
    """The token, made on first start: 0700 directory, 0600 file."""
    if TOKEN_FILE.is_file():
        tok = TOKEN_FILE.read_text().strip()
        if tok:
            return tok
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(TOKEN_FILE.parent, 0o700)
    tok = secrets.token_urlsafe(32)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(tok + "\n")
    os.chmod(TOKEN_FILE, 0o600)
    return tok


TOKEN = load_token()


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
    acc = run([ACCOUNTS, "--json"])
    st = run([ACCOUNTS, "status", "--json"])
    se = run([SESSIONS, "--json"])
    return {
        "accounts": parse(acc["stdout"], {}),
        "status": parse(st["stdout"], {}),
        "sessions": parse(se["stdout"], []),
        "terminal": TERMINAL_URL or None,
        "calls": {"accounts": acc, "status": st, "sessions": se},
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "flakelab-web/1.0"

    # --- plumbing -----------------------------------------------------------
    def log_message(
        self, fmt, *args
    ):  # one line per request on stderr, no client noise
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send_json(self, code, doc):
        body = json.dumps(doc).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authed(self) -> bool:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        return hmac.compare_digest(auth[7:].strip(), TOKEN)

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

    # --- routes -------------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?", 1)[0]
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
            self.send_json(200, {"ok": True})
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
        path = self.path.split("?", 1)[0]
        if not path.startswith("/api/"):
            self.send_json(404, {"error": "not found"})
            return
        if not self.authed():
            self.send_json(401, {"error": "a bearer token is required"})
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
