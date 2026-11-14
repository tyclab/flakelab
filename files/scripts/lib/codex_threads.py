#!/usr/bin/env python3
"""Codex conversations on the shared background server, through Codex's own protocol.

`flakelab sessions` (files/scripts/claude-sessions) calls this for what a Codex window
cannot be told on its command line or asked afterwards: start a conversation on a model
and a reasoning effort with a first prompt, read the state of conversations, and stop
one before its window is closed.

    codex_threads.py start --cwd DIR [--model M] [--effort E] [--name N] [--trust]   # prompt on stdin
    codex_threads.py state [--deadline SECONDS] ID...
    codex_threads.py close-check [--after-stop] ID
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
# For a whole stop, connecting included; an interrupt and a clean each took under 3 s when measured.
STOP_SECONDS = float(os.environ.get("FLAKELAB_CODEX_STOP_SECONDS", "30"))
# For the goodbye frame: nothing waits on a server that has stopped reading.
CLOSE_SECONDS = 1.0
ACTIVE = ("working", "approval", "question")
DECISIONS = ("trusted", "untrusted")
# What the server answers for a conversation it does not know ("thread not loaded: <id>").
INVALID_REQUEST = -32600


class Refusal(Exception):
    """Failed or refused work: exit 1."""

    code = 1


class Usage(Refusal):
    """A wrong argument, model or effort: exit 2."""

    code = 2


class RpcError(Refusal):
    """The server answered a call with an error: the call did not take effect."""

    def __init__(self, message, rpc_code=None):
        super().__init__(message)
        self.rpc_code = rpc_code


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
    messages in one or more frames, pings, close. Every read and every write ends at a
    deadline; the socket never blocks."""

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
        self.sock.setblocking(False)

    def _fill(self, deadline):
        if deadline.over():
            raise NoAnswer("no answer in time")
        try:
            ready, _, _ = select.select([self.sock], [], [], deadline.left())
            if not ready:
                raise NoAnswer("no answer in time")
            chunk = self.sock.recv(65536)
        except BlockingIOError:
            return
        except OSError as err:
            raise Refusal(f"the connection to the server broke ({err})") from None
        if not chunk:
            raise Refusal("the server closed the connection")
        self.buffer += chunk

    def _take(self, n, deadline):
        while len(self.buffer) < n:
            self._fill(deadline)
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def _send(self, opcode, payload, deadline):
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            head = bytes([0x80 | opcode, 0x80 | n])
        elif n < 65536:
            head = bytes([0x80 | opcode, 0x80 | 126]) + n.to_bytes(2, "big")
        else:
            head = bytes([0x80 | opcode, 0x80 | 127]) + n.to_bytes(8, "big")
        # The mask repeated to the payload's length, applied as one big number: a prompt can be megabytes.
        masked = (int.from_bytes(payload, "big") ^ int.from_bytes((mask * (n // 4 + 1))[:n], "big")).to_bytes(n, "big") if n else b""
        data = memoryview(head + mask + masked)
        while data:
            if deadline.over():
                raise NoAnswer("the server does not take the request")
            try:
                _, ready, _ = select.select([], [self.sock], [], deadline.left())
                if not ready:
                    raise NoAnswer("the server does not take the request")
                sent = self.sock.send(data)
            except BlockingIOError:
                continue
            except OSError as err:
                raise Refusal(f"the connection to the server broke ({err})") from None
            data = data[sent:]

    def send_text(self, text, deadline):
        self._send(0x1, text.encode(), deadline)

    def recv_text(self, deadline):
        """The next text message, its fragments joined; a ping in between is answered. A frame
        that does not fit the protocol ends the read: nothing is guessed from a broken stream."""
        message = None  # None: no message has begun
        while True:
            if deadline.over():
                raise NoAnswer("no answer in time")
            b0, b1 = self._take(2, deadline)
            opcode, final = b0 & 0x0F, bool(b0 & 0x80)
            n = b1 & 0x7F
            if b0 & 0x70 or b1 & 0x80:
                raise Refusal("the server sent a frame this client does not understand")
            if opcode >= 0x8:
                # Control frames are short, whole, and no part of the message they interrupt.
                if n > 125 or not final:
                    raise Refusal("the server sent a malformed control frame")
                payload = self._take(n, deadline)
                if opcode == 0x8:
                    raise Refusal("the server closed the connection")
                if opcode == 0x9:
                    self._send(0xA, payload, deadline)
                elif opcode != 0xA:
                    raise Refusal("the server sent an unknown control frame")
                continue
            if n == 126:
                n = int.from_bytes(self._take(2, deadline), "big")
            elif n == 127:
                n = int.from_bytes(self._take(8, deadline), "big")
            if opcode == 0x1:
                if message is not None:
                    raise Refusal("the server began a message inside an unfinished one")
                message = b""
            elif opcode == 0x0:
                if message is None:
                    raise Refusal("the server continued a message it never began")
            else:
                raise Refusal("the server sent a frame that is not text")
            if len(message) + n > MAX_MESSAGE:
                raise Refusal("the server sent a message above 16 MiB, the limit it announces")
            message += self._take(n, deadline)
            if final:
                try:
                    return message.decode("utf-8")
                except UnicodeDecodeError:
                    raise Refusal("the server sent text that is not UTF-8") from None

    def close(self):
        try:
            self._send(0x8, b"", Deadline(CLOSE_SECONDS))
        except Refusal:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


class Server:
    """One connection: requests out, their answers back. A message with a "method" is a
    notification or a request of the server's, whatever id it carries; it is passed over.

    With a deadline, connecting and every call together end at it: a call is not even
    sent once it has passed, so nothing is changed after the time a command was given."""

    def __init__(self, experimental=False, deadline=None):
        home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
        self.version = "unknown"
        self.next_id = 0
        self.overall = deadline
        # Codex makes this a link into a short directory; the resolved path also fits
        # a socket address where a long CODEX_HOME would not.
        path = os.path.realpath(os.path.join(home, "app-server-control", "app-server-control.sock"))
        self.ws = WebSocket(path, min(CONNECT_SECONDS, deadline.left()) if deadline else CONNECT_SECONDS)
        params: dict = {"clientInfo": CLIENT}
        if experimental:
            params["capabilities"] = {"experimentalApi": True}
        agent = self.need(self.call("initialize", params), "userAgent", "initialize", str)
        # "codex-tui/0.169.0 (...)": the running server's version, which an installed CLI need not share.
        self.version = agent.split(" ")[0].rpartition("/")[2] or agent
        self.ws.send_text(json.dumps({"method": "initialized"}), self._limit("initialized"))

    def where(self):
        return f"Codex server {self.version}"

    def _limit(self, method):
        if self.overall is None:
            return Deadline(CALL_SECONDS)
        if self.overall.over():
            raise NoAnswer(f"{method}: not sent, the time for this command is up ({self.where()})")
        return Deadline(min(CALL_SECONDS, self.overall.left()))

    def call(self, method, params=None):
        deadline = self._limit(method)
        self.next_id += 1
        want = self.next_id
        message = {"method": method, "id": want}
        if params is not None:
            message["params"] = params
        try:
            self.ws.send_text(json.dumps(message), deadline)
            while True:
                try:
                    answer = json.loads(self.ws.recv_text(deadline))
                except ValueError:
                    raise Refusal("the server sent a message that is not JSON") from None
                if isinstance(answer, dict) and "method" not in answer and answer.get("id") == want and not isinstance(answer.get("id"), bool):
                    break
        except NoAnswer as err:
            raise NoAnswer(f"{method}: {err} ({self.where()})") from None
        except Refusal as err:
            raise Refusal(f"{method}: {err} ({self.where()})") from None
        if "error" in answer:
            error = answer["error"] if isinstance(answer["error"], dict) else {"message": answer["error"]}
            raise RpcError(f"{method}: {str(error.get('message'))[:300]} ({self.where()})", error.get("code"))
        if not isinstance(answer.get("result"), dict):
            raise Refusal(f"{method}: the answer has no result ({self.where()})")
        return answer["result"]

    def need(self, obj, key, method, kind=None):
        if not isinstance(obj, dict) or key not in obj:
            raise Refusal(f"{method}: the answer has no '{key}' ({self.where()})")
        if kind is not None and not isinstance(obj[key], kind):
            raise Refusal(f"{method}: '{key}' in the answer is not what it should be ({self.where()})")
        return obj[key]

    def pages(self, method, params):
        """Every item of a paged list."""
        items, cursor, seen = [], None, set()
        while True:
            result = self.call(method, {**params, **({"cursor": cursor} if cursor else {})})
            items += self.need(result, "data", method, list)
            cursor = result.get("nextCursor")
            if not cursor:
                return items
            if not isinstance(cursor, str) or cursor in seen:
                raise Refusal(f"{method}: the server repeats its page cursor, the list cannot be read to its end ({self.where()})")
            seen.add(cursor)

    def close(self):
        self.ws.close()


# -- reading a conversation -------------------------------------------------------------


def state_of(server, thread):
    status = server.need(thread, "status", "thread/read", dict)
    kind = server.need(status, "type", "thread/read", str)
    if kind == "active":
        flags = status.get("activeFlags") or []
        if "waitingOnApproval" in flags:
            return "approval"
        return "question" if "waitingOnUserInput" in flags else "working"
    words = {"idle": "idle", "notLoaded": "unloaded", "systemError": "error"}
    if kind not in words:
        raise Refusal(f"thread/read: unknown status '{kind}' ({server.where()})")
    return words[kind]


def read(server, tid):
    result = server.call("thread/read", {"threadId": tid, "includeTurns": False})
    return server.need(result, "thread", "thread/read", dict)


def loaded_ids(server):
    return [str(i) for i in server.pages("thread/loaded/list", {})]


def helpers_of(server, tid):
    """The loaded conversations whose chain of parents leads to tid: its helper agents, at any
    depth. Raises when the set cannot be established: a caller must not take an incomplete
    set for "no helper is working"."""
    threads = {}
    for other in loaded_ids(server):
        if other == tid:
            continue
        try:
            thread = read(server, other)
        except RpcError:
            # Unloaded since the list was read: it runs nothing here. Anything else stops the command.
            if other in loaded_ids(server):
                raise
            continue
        parent = server.need(thread, "parentThreadId", "thread/read")
        if parent is not None and not isinstance(parent, str):
            raise Refusal(f"thread/read: 'parentThreadId' in the answer is not what it should be ({server.where()})")
        threads[other] = thread
    found, family, grew = [], {tid}, True
    while grew:
        grew = False
        for other, thread in threads.items():
            if other not in family and thread["parentThreadId"] in family:
                family.add(other)
                found.append((other, thread))
                grew = True
    return found


def terminals_of(server, tid):
    listed = server.pages("thread/backgroundTerminals/list", {"threadId": tid})
    return [str(t.get("command")) if isinstance(t, dict) else str(t) for t in listed]


# -- start ------------------------------------------------------------------------------


def resolve_model(models, want, configured):
    models = [m for m in models if isinstance(m, dict)]
    names = ", ".join(str(m.get("id")) for m in models)
    if not want:
        if configured is None:
            default = [m for m in models if m.get("isDefault")]
            if len(default) != 1:
                raise Usage("the server names no default model; pass --model")
            return default[0]
        want, origin = str(configured), "your default model"
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
    offered = model.get("supportedReasoningEfforts")
    efforts = [str(e.get("reasoningEffort") if isinstance(e, dict) else e) for e in (offered if isinstance(offered, list) else [])]
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
    """The effective config for cwd and its table of trust entries. Codex's schema makes
    the table optional: none means no folder has a decision. Anything else that is no
    table is refused, with --trust too."""
    config = server.need(server.call("config/read", {"cwd": cwd, "includeLayers": False}), "config", "config/read", dict)
    projects = config.get("projects")
    if projects is None:
        projects = {}
    if not isinstance(projects, dict):
        raise Refusal(f"config/read: 'projects' in the answer is no table ({server.where()})")
    return config, projects


def decision(projects, key):
    """trusted, untrusted, or None: an entry without one of the two words decides nothing."""
    entry = projects.get(key)
    level = entry.get("trust_level") if isinstance(entry, dict) else None
    return level if level in DECISIONS else None


def start(args):
    try:
        prompt = sys.stdin.buffer.read().decode("utf-8")
    except UnicodeDecodeError:
        raise Usage("the prompt is not UTF-8") from None
    if not prompt.strip():
        raise Usage("the prompt is empty")
    # The spelling the caller gave: a trust decision may be keyed by it, symlinks and all.
    cwd = os.path.abspath(args.cwd)
    if not os.path.isdir(cwd):
        raise Usage(f"no such directory: {cwd}")

    server = Server()
    # 1. Preflight: nothing is changed before model, effort and trust are settled.
    config, projects = projects_of(server, cwd)
    models = server.pages("model/list", {"includeHidden": True})
    entry = resolve_model(models, args.model, config.get("model"))
    model = server.need(entry, "model", "model/list", str)
    effort = resolve_effort(entry, args.effort, config.get("model_reasoning_effort"))

    # 2. Trust: Codex saves a trust entry by itself for a folder it holds no decision for.
    keys = trust_keys(cwd)
    if not args.trust and not any(decision(projects, key) for key in keys):
        raise Refusal(
            f"Codex holds no trust decision for {cwd} (or its repository): open it once with `codex` and answer, "
            "or pass --trust (Codex may then save that folder as trusted)"
        )

    # 3. The conversation. It has no file until its first turn. Only an error answer says
    # that nothing was created; every other failure leaves that open.
    try:
        started = server.call("thread/start", {"cwd": cwd, "model": model, "config": {"model_reasoning_effort": effort}})
        tid = server.need(server.need(started, "thread", "thread/start", dict), "id", "thread/start", str)
    except RpcError:
        raise
    except Refusal as err:
        raise type(err)(f"{err}; Codex may have created an empty conversation, which leaves no file") from None
    empty = f"the empty conversation {tid} leaves no file"
    if (started.get("model"), started.get("reasoningEffort")) != (model, effort):
        raise Refusal(f"thread/start answered {started.get('model')} {started.get('reasoningEffort')}, not {model} {effort}; {empty} ({server.where()})")

    try:
        # 4. An alarm, not a rollback: the entry is saved and the folder's settings were loaded.
        if not args.trust:
            _, after = projects_of(server, cwd)
            real = os.path.realpath(cwd)

            def concerns(key):
                other = os.path.realpath(key)
                return key in keys or real == other or real.startswith(other.rstrip("/") + "/")

            changed = [k for k in {**projects, **after} if concerns(k) and decision(after, k) != decision(projects, k)]
            if changed:
                names = ", ".join(f"{k} (was {decision(projects, k) or 'undecided'}, now {decision(after, k) or 'undecided'})" for k in sorted(changed))
                raise Refusal(f"Codex changed a trust entry that was not asked for: {names}; undo it in config.toml if unwanted")
        # 5.
        if args.name:
            server.call("thread/name/set", {"threadId": tid, "name": args.name})
    except Refusal as err:
        raise Refusal(f"{err}; {empty}") from None

    # 6. The first turn carries model and effort itself: a window that opens on a
    # conversation without a turn applies its own defaults to it. Once the request is on
    # its way, only an error answer says the turn did not start.
    try:
        turn = server.call("turn/start", {"threadId": tid, "model": model, "effort": effort, "input": [{"type": "text", "text": prompt}]})
        turn_id = server.need(server.need(turn, "turn", "turn/start", dict), "id", "turn/start", str)
    except RpcError as err:
        raise Refusal(f"{err}; {empty}") from None
    except Refusal as err:
        raise type(err)(f"{err}; the prompt may be running in session {tid} and is not sent again: codex resume {tid}") from None
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
        # state None: no answer, or an answer that was no state. "missing": the server does not know the id.
        row = {"session": tid, "state": None, "model": None, "effort": None, "name": None}
        out.append(row)
        if deadline and deadline.over():
            continue
        try:
            thread = read(server, tid)
        except NoAnswer:
            if deadline:
                continue
            raise
        except RpcError as err:
            if err.rpc_code == INVALID_REQUEST and tid in str(err):
                row["state"] = "missing"
            continue
        row.update(state=state_of(server, thread), model=thread.get("model"), effort=thread.get("reasoningEffort"), name=thread.get("name"))
    server.close()
    return out


# -- close ------------------------------------------------------------------------------

REASONS = {"working": "is working", "approval": "waits for an approval", "question": "waits for an answer", "error": "is in an error state"}


def close_check(args):
    """Is the session finished? After a forced stop an error state no longer counts against
    it: the stop has ended what it could, and the window may go."""
    blocking = {k: v for k, v in REASONS.items() if not (args.after_stop and k == "error")}
    server = Server(experimental=True)
    thread = read(server, args.id)
    now = state_of(server, thread)
    reasons = []
    if now != "unloaded":
        if now in blocking:
            reasons.append(f"the session {blocking[now]}")
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
            if now in blocking:
                reasons.append(f"the session {blocking[now]}")
    server.close()
    return {"session": args.id, "finished": not reasons, "state": now, "reasons": reasons, "cwd": thread.get("cwd"), "name": thread.get("name")}


def stop(args):
    # One deadline from before the connection: no interrupt and no clean is sent after it.
    deadline = Deadline(STOP_SECONDS)
    interrupted, cleaned = [], []
    try:
        server = Server(experimental=True, deadline=deadline)
        thread = read(server, args.id)
        if state_of(server, thread) == "unloaded":
            server.close()
            return {"session": args.id, "interrupted": [], "cleaned": []}
        members = [args.id, *[tid for tid, _ in helpers_of(server, args.id)]]

        def newest_turn(tid):
            listed = server.call("thread/turns/list", {"threadId": tid, "limit": 1, "sortDirection": "desc"})
            turns = server.need(listed, "data", "thread/turns/list", list)
            return turns[0] if turns and isinstance(turns[0], dict) else {}

        for tid in members:
            if state_of(server, read(server, tid)) not in ACTIVE:
                continue
            # An interrupt must name the active turn. If it is refused, look again: the turn
            # may have ended or been followed by another since it was read. The deadline
            # ends this: no call is sent after it.
            while True:
                turn = newest_turn(tid)
                if turn.get("status") != "inProgress":
                    break
                try:
                    server.call("turn/interrupt", {"threadId": tid, "turnId": turn.get("id")})
                    interrupted.append(tid)
                    break
                except RpcError:
                    again = newest_turn(tid)
                    if again.get("status") == "inProgress" and again.get("id") == turn.get("id"):
                        raise

        def wait(still_busy, what):
            busy = ["unknown"]
            while True:
                try:
                    busy = still_busy()
                except NoAnswer:
                    if not deadline.over():
                        raise
                if not busy:
                    return
                if deadline.over():
                    raise Refusal(f"after {STOP_SECONDS:g} s still {what}: {', '.join(busy)}")
                time.sleep(min(0.5, deadline.left()))

        wait(lambda: [tid for tid in members if state_of(server, read(server, tid)) in ACTIVE], "working")
        loaded = [tid for tid in members if state_of(server, read(server, tid)) != "unloaded"]
        for tid in loaded:
            server.call("thread/backgroundTerminals/clean", {"threadId": tid})
            cleaned.append(tid)
        wait(lambda: [c for tid in loaded for c in terminals_of(server, tid)], "running")
        server.close()
    except Refusal as err:
        # What was done before the failure is part of the answer: the session is no longer as it was.
        done = f"interrupted before that: {', '.join(interrupted) or 'none'}; background commands ended in: {', '.join(cleaned) or 'none'}"
        raise Refusal(f"{err}; {done}; no window was closed") from None
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
    p = sub.add_parser("close-check")
    p.add_argument("--after-stop", action="store_true")
    p.add_argument("id", metavar="ID")
    p.set_defaults(run=close_check)
    for name, run in (("stop", stop), ("archive", archive)):
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
    except (AttributeError, KeyError, TypeError, ValueError) as err:
        # An answer shaped unlike anything this file checks for: one line, never a traceback.
        print(f"Error: an answer of Codex's server could not be read ({type(err).__name__}: {err})", file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
