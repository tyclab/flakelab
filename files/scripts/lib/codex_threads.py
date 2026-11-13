#!/usr/bin/env python3
"""Codex conversations on the shared background server, through Codex's own protocol.

`flakelab sessions` (files/scripts/claude-sessions) calls this for what a Codex window
cannot be told on its command line or asked afterwards: start a conversation on a model
and a reasoning effort with a first prompt, read the state of conversations, and stop
one before its window is closed.

    codex_threads.py start --cwd DIR [--model M] [--effort E] [--name N] [--trust]   # prompt on stdin
    codex_threads.py state [--deadline SECONDS] ID...
    codex_threads.py close-check ID
    codex_threads.py stop ID
    codex_threads.py archive ID

Stdout is one JSON document. On failure stderr holds one "Error: ..." line and the exit
code is 2 for a usage error (also an unknown model or effort), 1 for failed or refused
work. Nothing here answers a request the server sends (it approves nothing).

The server is the one behind $CODEX_HOME/app-server-control/app-server-control.sock
(~/.codex without CODEX_HOME): a WebSocket carrying one JSON message per text frame.
What this file relies on was measured on codex-cli 0.169.0 and is written down in
docs/superpowers/specs/2026-11-13-sessions-codex-lanes-design.md (facts F1 to F13).
"""

import argparse
import base64
import hashlib
import json
import os
import select
import socket
import subprocess
import sys
import time

CLIENT = {"name": "flakelab-sessions", "version": "1"}
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
# The limit the server announces for one message (x-codex-websocket-max-unfragmented-message-bytes).
MAX_MESSAGE = 16 * 1024 * 1024
CONNECT_SECONDS = 5.0
# Per call; the slowest call measured took under 2 s. The env names are the suites' seams.
CALL_SECONDS = float(os.environ.get("FLAKELAB_CODEX_CALL_SECONDS", "30"))
# For a whole stop; an interrupt and a clean each took under 3 s when measured.
STOP_SECONDS = float(os.environ.get("FLAKELAB_CODEX_STOP_SECONDS", "30"))
ACTIVE = ("working", "approval", "question")


class Refusal(Exception):
    """Failed or refused work: exit 1."""

    code = 1


class Usage(Refusal):
    """A wrong argument, model or effort: exit 2."""

    code = 2


class RpcError(Refusal):
    """The server answered a call with an error."""


class NoAnswer(Refusal):
    """A call got no answer in time: whether it took effect is unknown."""


class Deadline:
    def __init__(self, seconds):
        self.end = time.monotonic() + seconds

    def left(self):
        return max(0.0, self.end - time.monotonic())

    def over(self):
        return time.monotonic() >= self.end


def accept_for(key):
    return base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()


class WebSocket:
    """The client side of RFC 6455 over a unix socket, as far as the server uses it: text
    messages in one or more frames, pings, close."""

    def __init__(self, path, seconds=CONNECT_SECONDS):
        self.buffer = b""
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(max(0.1, seconds))
        try:
            self.sock.connect(path)
            key = base64.b64encode(os.urandom(16)).decode()
            self.sock.sendall(
                (
                    "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
                ).encode()
            )
            deadline = Deadline(seconds)
            while b"\r\n\r\n" not in self.buffer:
                self._fill(deadline)
        except (OSError, Refusal) as err:
            raise Refusal(
                f"Codex's shared server does not answer at {path} ({err}): start a Codex session, or run: codex app-server daemon start"
            ) from None
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        headers = {k.strip().lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:])}
        if " 101 " not in lines[0] + " " or headers.get("sec-websocket-accept") != accept_for(key):
            raise Refusal(f"the WebSocket handshake at {path} was not accepted: {lines[0]}")
        self.sock.settimeout(None)

    def _fill(self, deadline):
        ready, _, _ = select.select([self.sock], [], [], deadline.left())
        if not ready:
            raise NoAnswer("no answer in time")
        chunk = self.sock.recv(65536)
        if not chunk:
            raise Refusal("the server closed the connection")
        self.buffer += chunk

    def _take(self, n, deadline):
        while len(self.buffer) < n:
            self._fill(deadline)
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def _send(self, opcode, payload):
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            head = bytes([0x80 | opcode, 0x80 | n])
        elif n < 65536:
            head = bytes([0x80 | opcode, 0x80 | 126]) + n.to_bytes(2, "big")
        else:
            head = bytes([0x80 | opcode, 0x80 | 127]) + n.to_bytes(8, "big")
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def send_text(self, text):
        self._send(0x1, text.encode())

    def recv_text(self, deadline):
        """The next text message, its fragments joined; a ping in between is answered."""
        message = b""
        while True:
            b0, b1 = self._take(2, deadline)
            n = b1 & 0x7F
            if n == 126:
                n = int.from_bytes(self._take(2, deadline), "big")
            elif n == 127:
                n = int.from_bytes(self._take(8, deadline), "big")
            if len(message) + n > MAX_MESSAGE:
                raise Refusal("the server sent a message above 16 MiB, the limit it announces")
            payload = self._take(n, deadline)
            opcode = b0 & 0x0F
            if opcode == 0x8:
                raise Refusal("the server closed the connection")
            if opcode == 0x9:
                self._send(0xA, payload)
            elif opcode in (0x0, 0x1, 0x2):
                message += payload
                if b0 & 0x80:
                    return message.decode()

    def close(self):
        try:
            self._send(0x8, b"")
        except OSError:
            pass
        self.sock.close()


class Server:
    """One connection: requests out, their answers back. A message with a "method" is a
    notification or a request of the server's, whatever id it carries; it is passed over."""

    def __init__(self, experimental=False, deadline=None):
        """deadline: for connecting and the opening exchange together (default: their own limits)."""
        home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
        self.version = "unknown"
        self.next_id = 0
        # Codex makes this a link into a short directory; the resolved path also fits
        # a socket address where a long CODEX_HOME would not.
        path = os.path.realpath(os.path.join(home, "app-server-control", "app-server-control.sock"))
        self.ws = WebSocket(path, min(CONNECT_SECONDS, deadline.left()) if deadline else CONNECT_SECONDS)
        params: dict = {"clientInfo": CLIENT}
        if experimental:
            params["capabilities"] = {"experimentalApi": True}
        agent = self.need(self.call("initialize", params, deadline), "userAgent", "initialize")
        # "codex-tui/0.169.0 (...)": the running server's version, which an installed CLI need not share.
        self.version = agent.split(" ")[0].rpartition("/")[2] or agent
        self.ws.send_text(json.dumps({"method": "initialized"}))

    def where(self):
        return f"Codex server {self.version}"

    def call(self, method, params=None, deadline=None):
        deadline = deadline or Deadline(CALL_SECONDS)
        self.next_id += 1
        message = {"method": method, "id": self.next_id}
        if params is not None:
            message["params"] = params
        self.ws.send_text(json.dumps(message))
        while True:
            try:
                answer = json.loads(self.ws.recv_text(deadline))
            except NoAnswer:
                raise NoAnswer(f"{method}: no answer in time ({self.where()})") from None
            if not isinstance(answer, dict) or "method" in answer or answer.get("id") != self.next_id:
                continue
            if "error" in answer:
                detail = answer["error"].get("message") if isinstance(answer["error"], dict) else answer["error"]
                raise RpcError(f"{method}: {str(detail)[:300]} ({self.where()})")
            if not isinstance(answer.get("result"), dict):
                raise Refusal(f"{method}: the answer has no result ({self.where()})")
            return answer["result"]

    def need(self, obj, key, method):
        if not isinstance(obj, dict) or key not in obj:
            raise Refusal(f"{method}: the answer has no '{key}' ({self.where()})")
        return obj[key]

    def pages(self, method, params):
        """Every item of a paged list."""
        items, cursor = [], None
        while True:
            result = self.call(method, {**params, **({"cursor": cursor} if cursor else {})})
            items += self.need(result, "data", method)
            cursor = result.get("nextCursor")
            if not cursor:
                return items

    def close(self):
        self.ws.close()


# -- reading a conversation -------------------------------------------------------------


def state_of(server, thread):
    status = server.need(thread, "status", "thread/read")
    kind = server.need(status, "type", "thread/read")
    if kind == "active":
        flags = status.get("activeFlags") or []
        if "waitingOnApproval" in flags:
            return "approval"
        return "question" if "waitingOnUserInput" in flags else "working"
    words = {"idle": "idle", "notLoaded": "unloaded", "systemError": "error"}
    if kind not in words:
        raise Refusal(f"thread/read: unknown status '{kind}' ({server.where()})")
    return words[kind]


def read(server, tid, deadline=None):
    result = server.call("thread/read", {"threadId": tid, "includeTurns": False}, deadline)
    return server.need(result, "thread", "thread/read")


def helpers_of(server, tid):
    """The loaded conversations whose chain of parents leads to tid: its helper agents."""
    parents = {}
    for other in server.need(server.call("thread/loaded/list", {}), "data", "thread/loaded/list"):
        if other != tid:
            parents[other] = read(server, other)
    found, grew = [], True
    while grew:
        grew = False
        for other, thread in parents.items():
            if other not in [f[0] for f in found] and thread.get("parentThreadId") in [tid, *[f[0] for f in found]]:
                found.append((other, thread))
                grew = True
    return found


def terminals_of(server, tid):
    return [str(t.get("command")) for t in server.pages("thread/backgroundTerminals/list", {"threadId": tid})]


# -- start ------------------------------------------------------------------------------


def resolve_model(models, want, configured):
    names = ", ".join(str(m.get("id")) for m in models)
    if not want:
        if configured is None:
            default = [m for m in models if m.get("isDefault")]
            if len(default) != 1:
                raise Usage("the server names no default model; pass --model")
            return default[0]
        want, origin = configured, "your default model"
    else:
        origin = "model"
    for field in ("id", "model", "displayName"):
        hits = [m for m in models if str(m.get(field, "")).lower() == want.lower()]
        if len(hits) > 1:
            raise Usage(f"'{want}' names several models: {', '.join(str(m.get('id')) for m in hits)}")
        if hits:
            return hits[0]
    raise Usage(f"{origin} '{want}' is not offered; the server offers: {names}")


def resolve_effort(model, want, configured):
    efforts = [str(e.get("reasoningEffort") if isinstance(e, dict) else e) for e in model.get("supportedReasoningEfforts") or []]
    if want:
        if want.lower() not in efforts:
            raise Usage(f"model {model.get('id')} has no effort '{want}'; it offers: {', '.join(efforts)}")
        return want.lower()
    if configured in efforts:
        return configured
    if model.get("defaultReasoningEffort") in efforts:
        return model["defaultReasoningEffort"]
    raise Usage(f"model {model.get('id')} names no default effort; pass --effort")


def repository_root(cwd):
    """The folder Codex keys a repository's trust by: the main repository, also for a worktree."""

    def git(*args):
        try:
            done = subprocess.run(["git", "-C", cwd, "rev-parse", *args], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return None
        return done.stdout.strip() if done.returncode == 0 and done.stdout.strip() else None

    common = git("--path-format=absolute", "--git-common-dir")
    if common and os.path.basename(common.rstrip("/")) == ".git":
        return os.path.dirname(common.rstrip("/"))
    return git("--show-toplevel")


def trust_keys(cwd):
    """The paths Codex looks a trust decision up by: the folder and its repository root,
    each by canonical and by given spelling (get_active_project in Codex's config crate)."""
    keys = [os.path.realpath(cwd), os.path.abspath(cwd)]
    root = repository_root(cwd)
    if root:
        keys += [os.path.realpath(root), root]
    return list(dict.fromkeys(keys))


def projects_of(server, cwd):
    config = server.need(server.call("config/read", {"cwd": cwd, "includeLayers": False}), "config", "config/read")
    projects = config.get("projects")
    return config, (projects if isinstance(projects, dict) else {})


def start(args):
    try:
        prompt = sys.stdin.buffer.read().decode("utf-8")
    except UnicodeDecodeError:
        raise Usage("the prompt is not UTF-8") from None
    if not prompt.strip():
        raise Usage("the prompt is empty")
    cwd = os.path.abspath(args.cwd)
    if not os.path.isdir(cwd):
        raise Usage(f"no such directory: {cwd}")

    server = Server()
    # 1. Preflight: nothing is changed before model, effort and trust are settled.
    config, projects = projects_of(server, cwd)
    models = server.pages("model/list", {"includeHidden": True})
    entry = resolve_model(models, args.model, config.get("model"))
    model = server.need(entry, "model", "model/list")
    effort = resolve_effort(entry, args.effort, config.get("model_reasoning_effort"))

    # 2. Trust: Codex saves a trust entry by itself for a folder it holds no decision for.
    if not args.trust and not any(key in projects for key in trust_keys(cwd)):
        raise Refusal(
            f"Codex holds no trust decision for {cwd} (or its repository): open it once with `codex` and answer, "
            "or pass --trust (Codex may then save that folder as trusted)"
        )

    # 3. The conversation. It has no file until its first turn.
    try:
        started = server.call("thread/start", {"cwd": cwd, "model": model, "config": {"model_reasoning_effort": effort}})
    except NoAnswer as err:
        raise NoAnswer(f"{err}; Codex may have created an empty conversation, which leaves no file") from None
    tid = server.need(server.need(started, "thread", "thread/start"), "id", "thread/start")
    empty = f"the empty conversation {tid} leaves no file"
    if (started.get("model"), started.get("reasoningEffort")) != (model, effort):
        raise Refusal(f"thread/start answered {started.get('model')} {started.get('reasoningEffort')}, not {model} {effort}; {empty} ({server.where()})")

    try:
        # 4. An alarm, not a rollback: the entry is saved and the folder's settings were loaded.
        if not args.trust:
            _, after = projects_of(server, cwd)
            real = os.path.realpath(cwd)
            new = [k for k in after if k not in projects and (real == os.path.realpath(k) or real.startswith(os.path.realpath(k).rstrip("/") + "/"))]
            if new:
                raise Refusal(f"Codex saved a trust entry that was not asked for: {', '.join(new)} (remove it from config.toml if unwanted)")
        # 5.
        if args.name:
            server.call("thread/name/set", {"threadId": tid, "name": args.name})
    except Refusal as err:
        raise Refusal(f"{err}; {empty}") from None

    # 6. The first turn carries model and effort itself: a window that opens on a
    # conversation without a turn applies its own defaults to it.
    try:
        turn = server.call("turn/start", {"threadId": tid, "model": model, "effort": effort, "input": [{"type": "text", "text": prompt}]})
    except NoAnswer as err:
        raise NoAnswer(f"{err}; the prompt may be running, it is not sent again: codex resume {tid}") from None
    except Refusal as err:
        raise Refusal(f"{err}; {empty}") from None
    turn_id = server.need(server.need(turn, "turn", "turn/start"), "id", "turn/start")
    server.close()
    return {"session": tid, "model": model, "effort": effort, "turn": turn_id, "server": server.version}


# -- state ------------------------------------------------------------------------------


def state(args):
    ids = list(dict.fromkeys(args.ids))
    # The deadline covers everything, the connection included: the table waits on this.
    deadline = Deadline(args.deadline) if args.deadline else None
    server = Server(deadline=deadline)
    out = []
    for tid in ids:
        row = {"session": tid, "state": None, "model": None, "effort": None, "name": None}
        out.append(row)
        if deadline and deadline.over():
            continue
        try:
            thread = read(server, tid, deadline and Deadline(deadline.left()))
        except NoAnswer:
            if deadline:
                continue
            raise
        except RpcError:
            row["state"] = "missing"
            continue
        row.update(state=state_of(server, thread), model=thread.get("model"), effort=thread.get("reasoningEffort"), name=thread.get("name"))
    server.close()
    return out


# -- close ------------------------------------------------------------------------------

REASONS = {"working": "is working", "approval": "waits for an approval", "question": "waits for an answer", "error": "is in an error state"}


def close_check(args):
    server = Server(experimental=True)
    thread = read(server, args.id)
    now = state_of(server, thread)
    reasons = []
    if now != "unloaded":
        if now in REASONS:
            reasons.append(f"the session {REASONS[now]}")
        members = [(args.id, thread), *helpers_of(server, args.id)]
        for tid, helper in members[1:]:
            word = state_of(server, helper)
            if word in REASONS:
                reasons.append(f"helper agent {helper.get('agentNickname') or helper.get('name') or tid} {REASONS[word]}")
        for tid, member in members:
            if state_of(server, member) == "unloaded":
                continue
            try:
                reasons += [f"runs: {command}" for command in terminals_of(server, tid)]
            except Refusal as err:
                reasons.append(f"its running commands could not be read ({err})")
        if not reasons:
            # The last look, immediately before the caller removes the window.
            thread = read(server, args.id)
            now = state_of(server, thread)
            if now in REASONS:
                reasons.append(f"the session {REASONS[now]}")
    server.close()
    return {"session": args.id, "finished": not reasons, "state": now, "reasons": reasons, "cwd": thread.get("cwd"), "name": thread.get("name")}


def stop(args):
    server = Server(experimental=True)
    deadline = Deadline(STOP_SECONDS)
    thread = read(server, args.id)
    if state_of(server, thread) == "unloaded":
        server.close()
        return {"session": args.id, "interrupted": [], "cleaned": []}
    members = [args.id, *[tid for tid, _ in helpers_of(server, args.id)]]
    interrupted, cleaned = [], []

    def newest_turn(tid):
        turns = server.need(server.call("thread/turns/list", {"threadId": tid, "limit": 1, "sortDirection": "desc"}), "data", "thread/turns/list")
        return turns[0] if turns else {}

    for tid in members:
        if state_of(server, read(server, tid)) not in ACTIVE:
            continue
        # An interrupt must name the active turn. If it is refused, look again: the turn
        # may have ended or been followed by another since it was read.
        while True:
            turn = newest_turn(tid)
            if turn.get("status") != "inProgress":
                break
            try:
                server.call("turn/interrupt", {"threadId": tid, "turnId": turn.get("id")})
                interrupted.append(tid)
                break
            except RpcError as err:
                again = newest_turn(tid)
                if again.get("status") == "inProgress" and again.get("id") == turn.get("id"):
                    raise
                if deadline.over():
                    raise Refusal(f"the turn of {tid} kept changing: {err}") from None

    def wait(still_busy, what):
        while True:
            busy = still_busy()
            if not busy:
                return
            if deadline.over():
                raise Refusal(f"after {STOP_SECONDS:g} s still {what}: {', '.join(busy)}; nothing was closed")
            time.sleep(0.5)

    wait(lambda: [tid for tid in members if state_of(server, read(server, tid)) in ACTIVE], "working")
    loaded = [tid for tid in members if state_of(server, read(server, tid)) != "unloaded"]
    for tid in loaded:
        server.call("thread/backgroundTerminals/clean", {"threadId": tid})
        cleaned.append(tid)
    wait(lambda: [c for tid in loaded for c in terminals_of(server, tid)], "running")
    server.close()
    return {"session": args.id, "interrupted": interrupted, "cleaned": cleaned}


def archive(args):
    server = Server()
    server.call("thread/archive", {"threadId": args.id})
    server.close()
    return {"session": args.id, "archived": True}


def main(argv=None):
    parser = argparse.ArgumentParser(prog="codex_threads.py", description="Codex conversations on the shared background server.")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("start")
    p.add_argument("--cwd", required=True)
    p.add_argument("--model")
    p.add_argument("--effort")
    p.add_argument("--name")
    p.add_argument("--trust", action="store_true")
    p.set_defaults(run=start)
    p = sub.add_parser("state")
    p.add_argument("--deadline", type=float)
    p.add_argument("ids", nargs="+", metavar="ID")
    p.set_defaults(run=state)
    for name, run in (("close-check", close_check), ("stop", stop), ("archive", archive)):
        p = sub.add_parser(name)
        p.add_argument("id", metavar="ID")
        p.set_defaults(run=run)
    args = parser.parse_args(argv)
    try:
        result = args.run(args)
    except Refusal as err:
        print(f"Error: {err}", file=sys.stderr)
        return err.code
    except OSError as err:
        print(f"Error: the connection to Codex's server failed: {err}", file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
